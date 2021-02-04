import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel getSocket(String url)=>HtmlWebSocketChannel.connect(url);