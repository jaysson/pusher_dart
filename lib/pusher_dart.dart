library pusher_dart;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

@immutable
class PusherAuth {
  final Map<String, String> headers;

  PusherAuth({this.headers});
}

@immutable
class PusherOptions {
  final String authEndpoint;
  final PusherAuth auth;
  final String cluster;

  PusherOptions({this.authEndpoint, this.auth, this.cluster = 'ap2'});
}

class Channel with _EventEmitter {
  final String name;
  String _data;
  Connection _connection;

  Channel(this.name, this._connection, [String _data]);

  bool trigger(String eventName, Object data) {
    try {
      _connection.webSocketChannel.sink
          .add(jsonEncode({'event': eventName, 'data': data}));
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> connect() async {
    String auth;
    if (name.startsWith('private-') || name.startsWith('presence-')) {
      auth = await _connection.authenticate(name);
    }
    return trigger('pusher:subscribe',
        {'channel': name, 'auth': auth, 'channel_data': _data});
  }
}

mixin _EventEmitter {
  final Map<String, Set<Function(Object data)>> _listeners = {};

  void bind(String eventName, Function(Object data) callback) {
    if (_listeners[eventName] == null) {
      _listeners[eventName] = Set<Function(Object data)>();
    }
    _listeners[eventName].add(callback);
  }

  void unbind(String eventName, Function(Object data) callback) {
    if (_listeners[eventName] != null) {
      _listeners[eventName].remove(callback);
    }
  }

  void _broadcast(String eventName, [Object data]) {
    (_listeners[eventName] ?? Set()).forEach((listener) {
      listener(data);
    });
  }
}

class Connection with _EventEmitter {
  String state = 'initialized';
  String socketId;
  String apiKey;
  PusherOptions options;
  int _retryIn = 1;
  IOWebSocketChannel webSocketChannel;
  final Map<String, Channel> channels = {};

  Connection(this.apiKey, this.options) {
    _connect();
  }

  _connect() {
    try {
      state = 'connecting';
      _broadcast('connecting');
      webSocketChannel = IOWebSocketChannel.connect(
          'wss://ws-${options.cluster}.pusher.com:443/app/$apiKey?protocol=5&client=dart-libPusher&version=0.1.0');
      webSocketChannel.stream.listen(_handleMessage);
    } catch (e) {
      // Give up if we have to tray again after an hour
      if (_retryIn > 3600) return;
      _retryIn++;
      Future.delayed(Duration(seconds: _retryIn ^ 2), _connect);
    }
  }

  Future<String> authenticate(String channelName) async {
    if (socketId == null)
      throw WebSocketChannelException(
          'Pusher has not yet established connection');
    final response = await http.post(options.authEndpoint,
        headers: options.auth.headers,
        body: jsonEncode({'channel_name': channelName, 'socket_id': socketId}));
    if (response.statusCode == 200) {
      return jsonDecode(response.body)['auth'];
    }
    throw response;
  }

  _handleMessage(Object message) {
    if (Pusher.log != null) Pusher.log(message);
    final json = Map<String, Object>.from(jsonDecode(message));
    final String eventName = json['event'];
    final data = json['data'];
    _broadcast(eventName, data);
    switch (eventName) {
      case 'pusher:connection_established':
        socketId = jsonDecode(data)['socket_id'];
        state = 'connected';
        _broadcast('connected', data);
        _subscribeAll();
        break;
      case 'pusher:error':
        _broadcast('error', data);
        _handlePusherError(data);
        break;
      default:
        _handleChannelMessage(json);
    }
  }

  _handleChannelMessage(Map<String, Object> message) {
    final channel = channels[message['channel']];
    if (channel != null) {
      channel._broadcast(message['event'], message['data']);
    }
  }

  Future disconnect() {
    state = 'disconnected';
    return webSocketChannel.sink.close();
  }

  Channel subscribe(String channelName, [String data]) {
    final channel = Channel(channelName, this, data);
    channels[channelName] = channel;
    if (state == 'connected') {
      channel.connect();
    }
    return channel;
  }

  _subscribeAll() {
    channels.forEach((channelName, channel) {
      channel.connect();
    });
  }

  void unsubscribe(String channelName) {
    channels.remove(channelName);
    webSocketChannel.sink.add(jsonEncode({
      'event': 'pusher:unsubscribe',
      'data': {'channel': channelName}
    }));
  }

  void _handlePusherError(Map<String, Object> json) {
    final int errorCode = json['code'];
    if (errorCode >= 4200) {
      _connect();
    } else if (errorCode > 4100) {
      Future.delayed(Duration(seconds: 2), _connect);
    }
  }
}

class Pusher with _EventEmitter {
  static Function log = (Object message) {
    print('Pusher: $message');
  };

  Connection _connection;

  Pusher(String apiKey, PusherOptions options) {
    _connection = Connection(apiKey, options);
  }

  void disconnect() {
    _connection.disconnect();
  }

  Channel channel(String channelName) {
    return _connection.channels[channelName];
  }

  Channel subscribe(String channelName, [String data]) {
    return _connection.subscribe(channelName, data);
  }

  void unsubscribe(String channelName) {
    _connection.unsubscribe(channelName);
  }
}
