import 'package:web_socket_channel/web_socket_channel.dart';

import 'stub.dart'
    if (dart.library.html) 'web.dart'
    if (dart.library.io) 'io.dart';

WebSocketChannel connect(String url) => getSocket(url);
