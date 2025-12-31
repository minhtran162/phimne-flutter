import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'constants.dart';
import 'util.dart';

Future main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  final working = await findWorkingPwaUrl(kPwaUris);
  
  if (working != null) {
    kPwaUri = working;
    kPwaHost = working.host;
  } else {
    kPwaUri = kPwaUris.first;
    kPwaHost = kPwaUri.host;
  }

  runApp(MaterialApp(
    title: 'Phim Nè',
    themeMode: ThemeMode.dark,
    darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF181818),
      ),
    home: const MyApp(),
    debugShowCheckedModeBanner: false,
  ));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

// Use WidgetsBindingObserver to listen when the app goes in background
// to stop, on Android, JavaScript execution and any processing that can be paused safely,
// such as videos, audio, and animations.
class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final GlobalKey webViewKey = GlobalKey();

  InAppWebViewController? webViewController;
  InAppWebViewSettings sharedSettings = InAppWebViewSettings(
    supportZoom: false,
    clearSessionCache: true,
    transparentBackground: true,
    limitsNavigationsToAppBoundDomains: true,
    // Allow media to play without user interaction.
    // Allow iframes to go fullscreen (for video players).
    iframeAllowFullscreen: true,
    // Hide the default scrollbars within the webview content itself
    disallowOverScroll: true,
    disableVerticalScroll: false,
    disableHorizontalScroll: true,
    verticalScrollBarEnabled: false,
    horizontalScrollBarEnabled: false,

    // Disable the back/forward swipe gestures.
    allowsBackForwardNavigationGestures: false,
  );

  bool isLoading = true;

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void dispose() {
    webViewController = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!kIsWeb) {
      if (webViewController != null &&
          defaultTargetPlatform == TargetPlatform.android) {
        if (state == AppLifecycleState.paused) {
          pauseAll();
        } else {
          resumeAll();
        }
      }
    }
  }

  void pauseAll() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      webViewController?.pause();
    }
    webViewController?.pauseTimers();
  }

  void resumeAll() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      webViewController?.resume();
    }
    webViewController?.resumeTimers();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(   
      onWillPop: () async {
        // detect Android back button click
        final controller = webViewController;
        if (controller != null) {
          if (await controller.canGoBack()) {
            controller.goBack();
            return false;
          }
        }
        return true;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF181818),
        appBar: AppBar(
          // remove the toolbar
          toolbarHeight: 0,
        ),
        body: Column(
          children: <Widget>[
            Expanded(
              child: Stack(
                children: [
                  FutureBuilder<bool>(
                    future: isNetworkAvailable(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return Container();
                      }
                      final bool networkAvailable = snapshot.data ?? false;
                      // Android-only
                      final cacheMode = networkAvailable
                          ? CacheMode.LOAD_DEFAULT
                          : CacheMode.LOAD_CACHE_ELSE_NETWORK;
                      // iOS-only
                      final cachePolicy = networkAvailable
                          ? URLRequestCachePolicy.USE_PROTOCOL_CACHE_POLICY
                          : URLRequestCachePolicy.RETURN_CACHE_DATA_ELSE_LOAD;
                      final webViewInitialSettings = sharedSettings.copy();
                      webViewInitialSettings.cacheMode = cacheMode;
                      return InAppWebView(
                        key: webViewKey,
                        initialUrlRequest:
                            URLRequest(url: kPwaUri, cachePolicy: cachePolicy),
                        initialSettings: webViewInitialSettings,
                        onLoadStart: (controller, url) {
                          setState(() {
                            isLoading = true;
                          });
                        },
                        shouldOverrideUrlLoading:
                            (controller, navigationAction) async {
                          // restrict navigation to target host, open external links in 3rd party apps
                          final uri = navigationAction.request.url;
                          if (uri != null &&
                              navigationAction.isForMainFrame &&
                              uri.host != kPwaHost &&
                              await canLaunchUrl(uri)) {
                            launchUrl(uri);
                            return NavigationActionPolicy.CANCEL;
                          }
                          return NavigationActionPolicy.ALLOW;
                        },
                        onLoadStop: (controller, url) async {
                          setState(() {
                            isLoading = false;
                          });
                          if (await isNetworkAvailable() &&
                              !(await isPWAInstalled())) {
                            // if network is available and this is the first time
                            setPWAInstalled();
                          }
                        },
                        onReceivedError: (controller, request, error) async {
                          final isForMainFrame = request.isForMainFrame ?? true;
                          if (isForMainFrame && !(await isNetworkAvailable())) {
                            if (!(await isPWAInstalled())) {
                              await controller.loadData(
                                  data: kHTMLErrorPageNotInstalled);
                            }
                          }
                        },
                      );
                    },
                  ),
                  // This is the new loading indicator part
                  if (isLoading)
                    const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF61AD83),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
