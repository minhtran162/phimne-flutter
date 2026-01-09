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
    themeMode: ThemeMode.system,
    theme: ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: Colors.white,
    ),
    darkTheme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF181818),
    ),
    builder: (context, child) {
      // child is the Home widget resolved with the latest Theme/MediaQuery
      return child!;
    },
    home: MyApp(),
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
  late Future<bool> _networkCheckFuture;

  InAppWebViewSettings sharedSettings = InAppWebViewSettings(
    supportZoom: false,
    clearSessionCache: true,
    transparentBackground: false,
    limitsNavigationsToAppBoundDomains: true,
    // Allow media to play without user interaction.
    // Allow iframes to go fullscreen (for video players).
    iframeAllowFullscreen: true,
    allowsInlineMediaPlayback: true,

    // Hide the default scrollbars within the webview content itself
    disallowOverScroll: true,
    disableVerticalScroll: false,
    disableHorizontalScroll: true,
    verticalScrollBarEnabled: false,
    horizontalScrollBarEnabled: false,

    // Disable the back/forward swipe gestures.
    allowsBackForwardNavigationGestures: false,

    // Enable the shouldOverrideUrlLoading event.
    useShouldOverrideUrlLoading: true,

    cacheEnabled: false, // Disables disk cache
    cacheMode: CacheMode.LOAD_NO_CACHE, // Android: force network
  );

  bool isLoading = true;

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    _networkCheckFuture = isNetworkAvailable();
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
    if (state == AppLifecycleState.detached) {
      _clearWebViewData();
    }

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

  Future<void> _clearWebViewData() async {
    // Clears all website data (cookies, local storage, cache, etc.)
    await InAppWebViewController.clearAllCache();
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
        backgroundColor: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF181818)
            : Colors.white,
        appBar: AppBar(
          // remove the toolbar
          toolbarHeight: 0,
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF181818)
              : Colors.white,
        ),
        body: Column(
          children: <Widget>[
            Expanded(
              child: Stack(
                children: [
                  FutureBuilder<bool>(
                    future: _networkCheckFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return Container(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                    ? const Color(0xFF181818)
                                    : Colors.white);
                      }

                      final webViewInitialSettings = sharedSettings.copy();
                      webViewInitialSettings.cacheMode =
                          CacheMode.LOAD_NO_CACHE;

                      return Container(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF181818)
                            : Colors.white,
                        child: InAppWebView(
                          key: webViewKey,
                          initialUrlRequest: URLRequest(
                              url: kPwaUri,
                              cachePolicy: URLRequestCachePolicy
                                  .RELOAD_IGNORING_LOCAL_AND_REMOTE_CACHE_DATA),
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
                            final isForMainFrame =
                                request.isForMainFrame ?? true;
                            if (isForMainFrame &&
                                !(await isNetworkAvailable())) {
                              if (!(await isPWAInstalled())) {
                                await controller.loadData(
                                    data: kHTMLErrorPageNotInstalled);
                              }
                            }
                          },
                        ),
                      );
                    },
                  ),
                  // This is the new loading indicator part
                  if (isLoading)
                    Container(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF181818)
                          : Colors.white,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Image.asset(
                              Theme.of(context).brightness == Brightness.dark
                                  ? 'assets/banner-light.png'
                                  : 'assets/banner-dark.png',
                              width: 180,
                              fit: BoxFit.contain,
                            ),
                            const SizedBox(height: 32),
                            const CircularProgressIndicator(
                              color: Color(0xFF61AD83),
                            ),
                          ],
                        ),
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
