import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:developer' as developer;

import 'package:flutter/material.dart';

class TestPos extends StatefulWidget {
  const TestPos({super.key});

  @override
  State<TestPos> createState() => _TestPosState();
}

class _TestPosState extends State<TestPos> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        color: Colors.blueGrey,
        child: Padding(
          padding: EdgeInsetsGeometry.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () {
                  sendTcpToPos("192.168.100.234", "62350848", 641);
                },
                child: const Text('TEST PAYMENT', style: TextStyle(color: Colors.white, fontSize: 20)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> sendTcpToPos(String terminalIp, String terminalName, int amount) async {
  final terminalPort = 6666;
  final payload = [terminalName, '010', '', amount.toString(), '', '', '', '', 'HR', '', '', '', '', '', '', '', ''].join('|');
  final messageBytes = buildEcrMessage(payload);

  developer.log('🔼 Sending payload: $payload');
  developer.log('🔼 ECR message: $messageBytes');

  Socket? socket;

  try {
    socket = await Socket.connect(terminalIp, terminalPort, timeout: Duration(seconds: 5));
    socket.add(messageBytes);
    await socket.flush();

    final response = await readAllEcrResponses(socket);

    // Loop response
    for (final message in response.split('\u0003\n')) {
      if (message.contains('Invalid request type')) {
        developer.log('❌ $message');
        continue;
      }

      if (message.isNotEmpty) {
        developer.log('🔼 POS response: $message');
      }
    }

    handlePosResponse(response, terminalIp, terminalName, amount);
  } catch (e) {
    developer.log('❌ TCP error: $e');
  } finally {
    socket?.destroy();
  }
}

Future<void> handlePosResponse(String response, String terminalIp, String terminalName, int amount) async {
  final messages = response.split('\u0003\n').where((m) => m.isNotEmpty).toList();

  // Status message and their confirmFlag
  final statusMap = {
    'transaction approved': 1,
    'Do not honor': 0,
    'Declined by issuer': 0,
    'Not sufficient funds': 0,
    'Expired card': 0,
    'Incorrect PIN': 0,
    'Exceeds withdrawal amount limit': 0,
    'Maximum number of times used': 0,
  };

  for (final rawMsg in messages) {
    final cleanMsg = rawMsg.replaceAll('\u0002', '').replaceAll('\u0003', '').trim();

    // Special case: Waiting for confirm message
    if (cleanMsg.contains('Waiting CONFIRM command for invoiceNr')) {
      final invoiceMatch = RegExp(r'invoiceNr[:= ]+(\d+)').firstMatch(cleanMsg);
      final invoiceNumber = invoiceMatch?.group(1);

      if (invoiceNumber != null) {
        developer.log('📄 Invoice number (waiting): $invoiceNumber');
        developer.log('🚫 Reject');
        sendRejectOrConfirmToPos(terminalIp, terminalName, int.parse(invoiceNumber), 0);

        await Future.delayed(Duration(seconds: 3));

        // After reject, send to payment
        sendTcpToPos(terminalIp, terminalName, amount);
      }
      return;
    }

    // Transaction response: must start with 010|
    if (cleanMsg.startsWith('010|')) {
      for (final entry in statusMap.entries) {
        if (cleanMsg.contains(entry.key)) {
          developer.log('✅ ${entry.key}');
          final fields = cleanMsg.split('|');

          if (fields.length > 8) {
            final invoiceNumber = fields[7];
            developer.log('📄 Invoice number: $invoiceNumber');
            sendRejectOrConfirmToPos(terminalIp, terminalName, int.parse(invoiceNumber), entry.value);
          }

          return;
        }
      }
    }
  }

  developer.log('❌ No transaction message was recognized.');
}

Future<void> sendRejectOrConfirmToPos(String terminalIp, String terminalName, int invoiceNumber, int confirmFlag) async {
  final terminalPort = 6666;
  final payload = [terminalName, '030', invoiceNumber, confirmFlag].join('|');
  final messageBytes = buildEcrMessage(payload);

  developer.log('🔼 Sending ECR payload: $payload');
  developer.log('🔼 Sending ECR message: $messageBytes');

  Socket? socket;

  try {
    socket = await Socket.connect(terminalIp, terminalPort, timeout: Duration(seconds: 5));
    socket.add(messageBytes);
    await socket.flush();

    await socket.cast<List<int>>().transform(utf8.decoder).join();
  } catch (e) {
    developer.log('❌ TCP error during REJECT/CONFIRM message: $e');
  } finally {
    socket?.destroy();
  }
}

List<int> buildEcrMessage(String payload) {
  const stx = 0x02;
  const etx = 0x03;
  const nl = 0x0A;

  final payloadBytes = ascii.encode(payload);
  return [stx, ...payloadBytes, etx, nl];
}

Future<String> readAllEcrResponses(Socket socket, {Duration timeout = const Duration(seconds: 10)}) async {
  final completer = Completer<String>();
  final buffer = <int>[];
  final responses = <String>[];
  Timer? timer;

  void maybeFinish() {
    final full = responses.join('\u0003\n');
    if (!completer.isCompleted) {
      completer.complete(full);
      socket.destroy();
      timer?.cancel();
    }
  }

  timer = Timer(timeout, maybeFinish);

  socket.listen(
    (data) {
      buffer.addAll(data);

      while (true) {
        final stxIndex = buffer.indexOf(0x02);
        if (stxIndex == -1) break;

        int etxIndex = -1;
        for (int i = stxIndex + 1; i < buffer.length - 1; i++) {
          if (buffer[i] == 0x03 && buffer[i + 1] == 0x0A) {
            etxIndex = i;
            break;
          }
        }

        if (etxIndex == -1) break;

        final msgBytes = buffer.sublist(stxIndex + 1, etxIndex);
        final payload = ascii.decode(msgBytes);
        responses.add(payload);
        buffer.removeRange(0, etxIndex + 2);

        // log immediately for visibility
        developer.log('🔼 POS response: $payload');

        // end early if specific keywords seen
        if (payload.contains('transaction approved') || payload.contains('Waiting CONFIRM')) {
          maybeFinish();
          return;
        }
      }
    },
    onError: (e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    },
  );

  return completer.future;
}
