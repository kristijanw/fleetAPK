import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late final WebViewController _controller;
  bool _posRequestSent = false;

  @override
  void initState() {
    super.initState();

    late final PlatformWebViewControllerCreationParams params;
    params = const PlatformWebViewControllerCreationParams();
    final WebViewController controller = WebViewController.fromPlatformCreationParams(params);

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            debugPrint('WebView is loading (progress : $progress%)');
          },
          onPageStarted: (String url) {
            debugPrint('Page started loading: $url');

            if (url.contains('/pos-waiting/') && !_posRequestSent) {
              final uri = Uri.parse(url);
              final terminalName = uri.queryParameters['terminal_id'];
              final terminalIp = uri.queryParameters['terminal_ip'];
              final amount = int.tryParse(uri.queryParameters['amount'] ?? '0') ?? 0;

              if (terminalName != null && terminalIp != null && amount > 0) {
                _posRequestSent = true;
                sendTcpToPos(_controller, terminalIp, terminalName, amount);
              } else {
                print('❌ Missing parameters in URL');
              }
            }

            if (!url.contains('/pos-waiting/')) {
              _posRequestSent = false;
            }
          },
          onWebResourceError: (WebResourceError error) {
            print("❌ Web resource error: ${error.errorType} - ${error.description}");
          },
          onPageFinished: (String url) {
            debugPrint('Page finished loading: $url');
          },
          onNavigationRequest: (NavigationRequest request) {
            debugPrint('allowing navigation to ${request.url}');
            return NavigationDecision.navigate;
          },
          onHttpError: (HttpResponseError error) {
            debugPrint('Error occurred on page: ${error.response?.statusCode}');
          },
        ),
      )
      ..addJavaScriptChannel(
        'Toaster',
        onMessageReceived: (JavaScriptMessage message) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message.message)));
        },
      )
      ..clearCache()
      ..loadRequest(Uri.parse('https://bookingfleet.hr/'));

    _controller = controller;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: WebViewWidget(controller: _controller));
  }
}

Future<void> sendTcpToPos(WebViewController controller, String terminalIp, String terminalName, int amount) async {
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

    final messages = response.split('\u0003\n').where((m) => m.isNotEmpty).toList();
    final transactionMessage = messages
        .map((m) => m.replaceAll('\u0002', '').replaceAll('\u0003', '').trim())
        .firstWhere((msg) => msg.startsWith('010|'), orElse: () => '');

    if (transactionMessage.isNotEmpty) {
      final encoded = jsonEncode(transactionMessage);
      developer.log('📤 Sending transaction message to JavaScript: $encoded');
      await controller.runJavaScript("window.postMessage($encoded, '*');");
    } else {
      await controller.runJavaScript("window.postMessage(null, '*');");
      developer.log('⚠️ No transaction message (010|) to send.');
    }

    handlePosResponse(response, terminalIp, terminalName, amount, controller);
  } catch (e) {
    developer.log('❌ TCP error: $e');
  } finally {
    socket?.destroy();
  }
}

Future<void> handlePosResponse(String response, String terminalIp, String terminalName, int amount, WebViewController controller) async {
  final rawMessages = response.split('\u0003\n').where((m) => m.isNotEmpty).toList();
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

  developer.log('🔍 Raw POS message count: ${rawMessages.length}');

  for (final rawMsg in rawMessages) {
    final cleanMsg = rawMsg.replaceAll('\u0002', '').replaceAll('\u0003', '').replaceAll('\n', '').trim();

    developer.log('🧪 Checking POS message: $cleanMsg');

    // Handle "Waiting CONFIRM"
    if (cleanMsg.contains('Waiting CONFIRM command for invoiceNr')) {
      final invoiceMatch = RegExp(r'invoiceNr[:= ]+(\d+)').firstMatch(cleanMsg);
      final invoiceNumber = invoiceMatch?.group(1);

      if (invoiceNumber != null) {
        developer.log('📄 Invoice number (waiting): $invoiceNumber');
        developer.log('🚫 Reject');
        await sendRejectOrConfirmToPos(terminalIp, terminalName, int.parse(invoiceNumber), 0);

        // Delay to allow POS to reset
        await Future.delayed(Duration(seconds: 1));

        // Retry payment
        await sendTcpToPos(controller, terminalIp, terminalName, amount);
      } else {
        developer.log('❌ Could not extract invoice number from CONFIRM message.');
      }
      return;
    }

    // Transaction result
    if (cleanMsg.startsWith('010|') || cleanMsg.contains('010|')) {
      for (final entry in statusMap.entries) {
        if (cleanMsg.toLowerCase().contains(entry.key.toLowerCase())) {
          developer.log('✅ ${entry.key}');
          final fields = cleanMsg.split('|');

          if (fields.length > 8) {
            final invoiceNumber = fields[7];
            developer.log('📄 Invoice number: $invoiceNumber');
            await sendRejectOrConfirmToPos(terminalIp, terminalName, int.tryParse(invoiceNumber) ?? 0, entry.value);
          } else {
            developer.log('⚠️ 010| message found but invoice field is missing');
          }

          return;
        }
      }

      developer.log('❓ Found 010| message but no known status match.');
    } else {
      developer.log('❓ Unrecognized POS response: $cleanMsg');
    }
  }

  developer.log('❌ No transaction message was recognized.');

  final userDidNotRespond = rawMessages.any(
    (msg) => msg.contains('Waiting for user input') || msg.contains('|062|') || msg.contains('001|') && msg.contains('|1|Processing'),
  );

  // Ako je prepoznat "tišina" scenarij, obavijesti web
  if (userDidNotRespond) {
    final padded = List.filled(12, '', growable: false);
    padded[0] = '001'; // response type
    padded[1] = terminalName;
    padded[2] = '3'; // custom status code
    padded[11] = 'Payment failed.'; // message

    final paddedResponse = padded.join('|');
    developer.log('📤 Sending padded fallback: $paddedResponse');
    await controller.runJavaScript("window.postMessage('$paddedResponse', '*');");
  }
}

Future<void> sendRejectOrConfirmToPos(String terminalIp, String terminalName, int invoiceNumber, int confirmFlag) async {
  final terminalPort = 6666;
  final payload = [terminalName, '030', invoiceNumber, confirmFlag].join('|');
  final messageBytes = buildEcrMessage(payload);

  developer.log('🔼 Sending ECR payload: $payload');
  developer.log('🔼 Sending ECR message: $messageBytes');

  Socket? socket;
  final buffer = <int>[];
  final responses = <String>[];
  final timeout = Duration(seconds: 10);
  Timer? timer;
  final completer = Completer<void>();

  void maybeFinish() {
    if (!completer.isCompleted) {
      final full = responses.join('\u0003\n');
      developer.log('📥 Full POS confirm response: $full');
      completer.complete();
      socket?.destroy();
      timer?.cancel();
    }
  }

  try {
    socket = await Socket.connect(terminalIp, terminalPort, timeout: Duration(seconds: 5));
    socket.add(messageBytes);
    await socket.flush();

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
          final payload = ascii.decode(msgBytes, allowInvalid: true);
          responses.add(payload);
          buffer.removeRange(0, etxIndex + 2);

          developer.log('📥 POS confirm sub-response: $payload');

          // Ako želiš završiti ranije ako vidiš određenu frazu:
          if (payload.contains('transaction approved') || payload.contains('RECEIPT') || payload.contains('end of response')) {
            maybeFinish();
            return;
          }
        }
      },
      onDone: () {
        developer.log('ℹ️ POS confirm socket closed.');
        maybeFinish();
      },
      onError: (e) {
        developer.log('❌ Error during confirm socket: $e');
        if (!completer.isCompleted) completer.completeError(e);
        socket?.destroy();
        timer?.cancel();
      },
      cancelOnError: true,
    );

    await completer.future;
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
        final payload = ascii.decode(msgBytes, allowInvalid: true);
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
