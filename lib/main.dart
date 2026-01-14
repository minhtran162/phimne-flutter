import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dart:io';
import 'dart:collection';
import 'package:flutter/services.dart'
    show MethodChannel, SystemChrome, SystemUiMode, SystemNavigator;

import 'constants.dart';
import 'util.dart';

// === DEBUG FLAGS ===
// Set this to FALSE if the app fails to load (white screen) to confirm if NativeShell is the cause.
const bool kInjectNativeShell = true;

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
  late Future<bool> _networkCheckFuture;

  static String getJellyfinUserAgent() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X; Phim Ne iOS) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) '
            'Version/17.0 Mobile/15E148 Safari/604.1';

      case TargetPlatform.macOS:
        return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0; Phim Ne macOS) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) '
            'Version/17.0 Safari/605.1.15';

      default:
        return 'Mozilla/5.0 (Phim Ne) AppleWebKit/537.36 (KHTML, like Gecko)';
    }
  }

  InAppWebViewSettings sharedSettings = InAppWebViewSettings(
    supportZoom: false,
    clearSessionCache: true,
    transparentBackground: false,
    limitsNavigationsToAppBoundDomains: true,
    javaScriptCanOpenWindowsAutomatically: true,
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
    cacheEnabled: false,
    cacheMode: CacheMode.LOAD_NO_CACHE,
    userAgent: getJellyfinUserAgent(),
    useOnLoadResource: true,

    // iOS specific - ensure hardware acceleration
    allowsLinkPreview: false,
    ignoresViewportScaleLimits: true,
    suppressesIncrementalRendering: false, // Don't suppress rendering!
  );

  bool isLoading = true;
  bool isLocked = false;
  Timer? _longPressTimer;
  double _lockProgress = 0.0;
  static const MethodChannel _lockdownChannel =
      MethodChannel('phimne/lockdown');

  // Method to get device information
  Future<Map<String, String>> _getDeviceInfo() async {
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    final PackageInfo packageInfo = await PackageInfo.fromPlatform();

    String deviceId = '';
    String deviceName = '';
    String appName = '';

    try {
      if (kIsWeb) {
        deviceId = 'Web';
        deviceName = 'Phim Ne';
        appName = "Phim Ne";
      } else if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        deviceId = androidInfo.id;
        deviceName = '${androidInfo.manufacturer} ${androidInfo.model}';
        appName = "Phim Ne Android";
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        deviceId = iosInfo.identifierForVendor ?? '';
        deviceName = '${iosInfo.name} (${iosInfo.model})';
        appName = "Phim Ne iOS";
      } else if (Platform.isMacOS) {
        MacOsDeviceInfo macOsInfo = await deviceInfo.macOsInfo;
        deviceId = macOsInfo.systemGUID ?? '';
        deviceName = macOsInfo.model;
        appName = "Phim Ne macOS";
      }
    } catch (e) {
      debugPrint('Error getting device info: $e');
    }

    return {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'appName': appName,
      'appVersion': packageInfo.version,
    };
  }

// Helper method to safely escape JSON values for injection
  String _escapeForJson(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }

  // Create UserScript that injects native adapter script
  Future<UserScript> _createDeviceInfoUserScript() async {
    debugPrint('=== _createDeviceInfoUserScript START ===');

    final deviceInfo = await _getDeviceInfo();

    final deviceId = _escapeForJson(deviceInfo['deviceId'] ?? '');
    final deviceName = _escapeForJson(deviceInfo['deviceName'] ?? '');
    final appName = _escapeForJson(deviceInfo['appName'] ?? '');
    final appVersion = _escapeForJson(deviceInfo['appVersion'] ?? '');

    final source = '''
      (function() {
        window.NativeInterface = {
          getDeviceInformation: function() {
            try {
              return JSON.stringify({
                deviceId: "$deviceId",
                deviceName: "$deviceName",
                appName: "$appName",
                appVersion: "$appVersion"
              });
            } catch (e) {
              return "{}";
            }
          },
          enableFullscreen: function() {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('nativeInterface', {
                method: 'enableFullscreen'
              });
            }
          },
          disableFullscreen: function() {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('nativeInterface', {
                method: 'disableFullscreen'
              });
            }
          },
          openUrl: function(url) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('nativeInterface', {
                method: 'openUrl',
                url: url
              });
            }
          },
          updateMediaSession: function(mediaInfo) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('nativeInterface', {
                method: 'updateMediaSession',
                mediaInfo: mediaInfo
              });
            }
          },
          hideMediaSession: function() {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('nativeInterface', {
                method: 'hideMediaSession'
              });
            }
          },
          updateVolumeLevel: function(value) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('nativeInterface', {
                method: 'updateVolumeLevel',
                value: value
              });
            }
          },
          downloadFiles: function(downloadInfoJson) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('nativeInterface', {
                method: 'downloadFiles',
                downloads: downloadInfoJson
              });
            }
          },
          openClientSettings: function() {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('nativeInterface', {
                method: 'openClientSettings'
              });
            }
          },
          openServerSelection: function() {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('nativeInterface', {
                method: 'openServerSelection'
              });
            }
          },
          execCast: function(action, argsJson) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('nativeInterface', {
                method: 'execCast',
                action: action,
                args: argsJson
              });
            }
          },
          exitApp: function() {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('nativeInterface', {
                method: 'exitApp'
              });
            }
          }
        };
      })();
      ''';

    final userScript = UserScript(
      groupName: "deviceInfo",
      source: source,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      forMainFrameOnly: true,
    );

    debugPrint('UserScript created successfully');
    return userScript;
  }

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    _networkCheckFuture = isNetworkAvailable();
    super.initState();
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
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

  Future<void> _applyLockState() async {
    if (isLocked) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (webViewController != null) {
        await webViewController!.setSettings(
          settings: InAppWebViewSettings(disableVerticalScroll: true),
        );
      }
      if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb) {
        try {
          await _lockdownChannel.invokeMethod<bool>('startLockTaskMode');
        } catch (_) {}
      }
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (webViewController != null) {
        await webViewController!.setSettings(
          settings: InAppWebViewSettings(disableVerticalScroll: false),
        );
      }
      if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb) {
        try {
          await _lockdownChannel.invokeMethod<bool>('stopLockTaskMode');
        } catch (_) {}
      }
    }
  }

  void _onLockButtonPressStart() {
    _longPressTimer?.cancel();
    _longPressTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      bool toggled = false;
      setState(() {
        _lockProgress += 0.05 / 5.0; // 50ms / 5000ms = 0.01 per tick
        if (_lockProgress >= 1.0) {
          _lockProgress = 1.0;
          timer.cancel();
          // Toggle lock state
          isLocked = !isLocked;
          _lockProgress = 0.0;
          toggled = true;
        }
      });
      if (toggled) {
        _applyLockState();
      }
    });
  }

  void _onLockButtonPressEnd() {
    _longPressTimer?.cancel();
    setState(() {
      _lockProgress = 0.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (isLocked) {
          return false;
        }
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
          backgroundColor: const Color(0xFF181818),
        ),
        body: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                Expanded(
                  child: Stack(
                    children: [
                      FutureBuilder<bool>(
                        future: _networkCheckFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return Container(
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? const Color(0xFF181818)
                                    : Colors.white);
                          }
                          return FutureBuilder<UserScript>(
                            future: _createDeviceInfoUserScript(),
                            builder: (context, userScriptSnapshot) {
                              if (!userScriptSnapshot.hasData) {
                                return Container(
                                    color: Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? const Color(0xFF181818)
                                        : Colors.white);
                              }

                              final webViewInitialSettings =
                                  sharedSettings.copy();
                              webViewInitialSettings.cacheMode =
                                  CacheMode.LOAD_NO_CACHE;

                              return Container(
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? const Color(0xFF181818)
                                    : Colors.white,
                                child: InAppWebView(
                                  key: webViewKey,
                                  initialUrlRequest: URLRequest(
                                      url: kPwaUri,
                                      cachePolicy: URLRequestCachePolicy
                                          .RELOAD_IGNORING_LOCAL_AND_REMOTE_CACHE_DATA),
                                  initialSettings: webViewInitialSettings,
                                  initialUserScripts:
                                      UnmodifiableListView<UserScript>([
                                    userScriptSnapshot.data!,
                                  ]),
                                  onWebViewCreated: (controller) async {
                                    webViewController = controller;
                                    await _applyLockState();

                                    controller.addJavaScriptHandler(
                                      handlerName: 'nativeInterface',
                                      callback: (args) async {
                                        if (args.isEmpty) {
                                          return;
                                        }
                                        final dynamic payload = args.first;
                                        if (payload is! Map) {
                                          return;
                                        }

                                        final method =
                                            payload['method'] as String?;
                                        switch (method) {
                                          case 'enableFullscreen':
                                            await SystemChrome
                                                .setEnabledSystemUIMode(
                                              SystemUiMode.immersiveSticky,
                                            );
                                            break;
                                          case 'disableFullscreen':
                                            await SystemChrome
                                                .setEnabledSystemUIMode(
                                              SystemUiMode.edgeToEdge,
                                            );
                                            break;
                                          case 'openUrl':
                                            final url =
                                                payload['url'] as String?;
                                            if (url != null) {
                                              final uri = Uri.parse(url);
                                              if (await canLaunchUrl(uri)) {
                                                await launchUrl(
                                                  uri,
                                                  mode: LaunchMode
                                                      .externalApplication,
                                                );
                                              }
                                            }
                                            break;
                                          case 'downloadFiles':
                                            final downloadsJson =
                                                payload['downloads'] as String?;
                                            if (downloadsJson != null) {
                                              try {
                                                final uri =
                                                    Uri.parse(downloadsJson);
                                                if (await canLaunchUrl(uri)) {
                                                  await launchUrl(
                                                    uri,
                                                    mode: LaunchMode
                                                        .externalApplication,
                                                  );
                                                }
                                              } catch (_) {}
                                            }
                                            break;
                                          case 'exitApp':
                                            if (Platform.isAndroid ||
                                                Platform.isIOS) {
                                              await SystemNavigator.pop();
                                            }
                                            break;
                                          case 'updateMediaSession':
                                          case 'hideMediaSession':
                                          case 'updateVolumeLevel':
                                          case 'openClientSettings':
                                          case 'openServerSelection':
                                          case 'execCast':
                                          default:
                                            break;
                                        }
                                      },
                                    );
                                  },
                                  onLoadStart: (controller, url) {
                                    setState(() {
                                      isLoading = true;
                                    });
                                  },
                                  onLoadStop: (controller, url) async {
                                    setState(() {
                                      isLoading = false;
                                    });

                                    if (await isNetworkAvailable() &&
                                        !(await isPWAInstalled())) {
                                      setPWAInstalled();
                                    }
                                  },
                                  onProgressChanged: (controller, progress) {
                                    if (progress == 100) {
                                      debugPrint("WebView loaded 100%");
                                    }
                                  },
                                  onConsoleMessage:
                                      (controller, consoleMessage) {},
                                  onReceivedError:
                                      (controller, request, error) async {
                                    debugPrint('=== onReceivedError ===');
                                    debugPrint('Error: ${error.description}');

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
                                  shouldOverrideUrlLoading:
                                      (controller, navigationAction) async {
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
                                ),
                              );
                            },
                          );
                        },
                      ),
                      // Loading indicator
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
                                  Theme.of(context).brightness ==
                                          Brightness.dark
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
            // Lock overlay
            if (isLocked)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  onPanUpdate: (_) {},
                  child: Container(
                    color: Colors.transparent,
                  ),
                ),
              ),
            // Floating lock button
            if (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS)
              Positioned(
                right: 16,
                bottom: 10,
                child: GestureDetector(
                  onLongPressStart: (_) => _onLockButtonPressStart(),
                  onLongPressEnd: (_) => _onLockButtonPressEnd(),
                  onLongPressCancel: () => _onLockButtonPressEnd(),
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (_lockProgress > 0)
                          SizedBox(
                            width: 56,
                            height: 56,
                            child: CircularProgressIndicator(
                              value: _lockProgress,
                              strokeWidth: 3,
                              color: const Color(0xFF61AD83),
                              backgroundColor: Colors.transparent,
                            ),
                          ),
                        Icon(
                          isLocked ? Icons.lock : Icons.lock_open,
                          color: Colors.white.withValues(alpha: 0.2),
                          size: 28,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
