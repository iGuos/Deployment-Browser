import 'deployment_main_io.dart' if (dart.library.html) 'deployment_main_web.dart' as deployment;

/// Web 与 IO 分离入口：Web 不依赖 `desktop_multi_window` / `window_manager` 的桌面初始化。
Future<void> main(List<String> args) => deployment.deploymentMain(args);
