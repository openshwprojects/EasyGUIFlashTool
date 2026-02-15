// Export the SerialTransport interface
export 'serial_transport.dart';

// Conditional import for platform-specific implementations
export 'serial_io_stub.dart'
    if (dart.library.io) 'serial_io_mobile.dart'
    if (dart.library.js_interop) 'serial_io_web.dart';
