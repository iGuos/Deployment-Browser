library;

export 'proxy_settings_standalone_app.dart';
export 'window/proxy_window_io.dart'
    if (dart.library.html) 'window/proxy_window_stub.dart';
