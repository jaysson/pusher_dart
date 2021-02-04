library pusher_dart;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'web_socket/socket.dart';



/// Class to hold headers to send to authentication endpoint
/// Ex. `PusherAuth(headers: {'Authorization': 'Bearer $token'})`
@immutable
class PusherAuth {
  /// HTTP Headers
  /// Ex. `{'Authorization': 'Bearer $token'}`
  final Map<String, String> headers;

  /// Default constructor
  PusherAuth({this.headers});
}

/// Class to hold pusher configuration
/// Ex. `PusherOptions({authEndpoint: 'https://domain.com/auth', cluster: 'ap2', auth:  })`
@immutable
class PusherOptions {
  /// A URL string to send the authentication request to
  final String authEndpoint;
  final PusherAuth auth;

  // for using a different host or port
  final String host;
  final int port;

  //use wss or ws
  final bool encrypted;

  /// Pusher cluster
  /// @see https://pusher.com/docs/channels/miscellaneous/clusters
  final String cluster;

  /// Default constructor
  PusherOptions(
      {this.authEndpoint,
      this.auth,
      this.cluster = 'ap2',
      this.host,
      this.port = 443,
      this.encrypted = true});
}

/// A channel
class Channel with _EventEmitter {
  /// Channel name
  /// Ex. `private-Customer.1`
  final String name;
  String _data;
  Connection _connection;

  /// Default constructor
  Channel(this.name, this._connection, [String _data]);

  /// @see https://pusher.com/docs/channels/getting_started/javascript#listen-for-events-on-your-channel
  bool trigger(String eventName, Object data) {
    try {
      _connection.webSocketChannel.sink
          .add(jsonEncode({'event': eventName, 'data': data}));
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Subscribes to the channel
  /// If it is a private channel, authenticates using provided details
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

/// The main connection class for pusher
/// It holds the state, reconnects if necessary, and forwards method calls
class Connection with _EventEmitter {
  /// @see https://pusher.com/docs/channels/using_channels/connection#available-states
  String state = 'initialized';

  /// Socket ID provided by pusher
  String socketId;

  /// Get the API key from pusher dashboard.
  String apiKey;
  PusherOptions options;
  int _retryIn = 1;
  WebSocketChannel webSocketChannel;
  final Map<String, Channel> channels = {};

  /// Default constructor
  Connection(this.apiKey, this.options) {
    _connect();
  }

  _connect() {
    try {
      state = 'connecting';
      _broadcast('connecting');

      String protocol = options.encrypted ? 'wss://' : 'ws://';
      String host = options.host ?? 'ws-${options.cluster}.pusher.com';

      String domain = protocol + host + ":" + options.port.toString();
      if (Pusher.log != null) Pusher.log('connecting to ' + domain);

      webSocketChannel =connect(domain +
          '/app/$apiKey?protocol=5&client=dart-libPusher&version=0.1.0');

      webSocketChannel.stream.listen(_handleMessage);
    } catch (e) {
      // Give up if we have to tray again after an hour
      if (_retryIn > 3600) return;
      _retryIn++;
      Future.delayed(Duration(seconds: _retryIn ^ 2), _connect);
    }
  }

  /// Authenticate a specific channel
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

  /// Disconnect from pusher
  Future disconnect() {
    state = 'disconnected';
    return webSocketChannel.sink.close();
  }

  /// Subscribe to channel using channel name
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

  /// Unsubscribe a channel using channel name
  /// @see https://pusher.com/docs/channels/getting_started/javascript#subscribe-to-a-channel
  void unsubscribe(String channelName) {
    channels.remove(channelName);
    webSocketChannel.sink.add(jsonEncode({
      'event': 'pusher:unsubscribe',
      'data': {'channel': channelName}
    }));
  }

  void _handlePusherError(Map<String, Object> json) {
    final int errorCode =
        json == null || json['code'] == null ? 1 : json['code'];
    if (errorCode >= 4200) {
      _connect();
    } else if (errorCode > 4100) {
      Future.delayed(Duration(seconds: 2), _connect);
    }
  }
}

class Pusher with _EventEmitter {
  /// Log function called on all pusher actions
  static Function log = (Object message) {
    print('Pusher: $message');
  };

  Connection _connection;

  /// Default constructor
  Pusher(String apiKey, PusherOptions options) {
    _connection = Connection(apiKey, options);
  }

  /// Disconnect from pusher
  void disconnect() {
    _connection.disconnect();
  }

  /// Get a channel using channel name
  Channel channel(String channelName) {
    return _connection.channels[channelName];
  }

  /// Subscribe to a channel using channel name
  Channel subscribe(String channelName, [String data]) {
    return _connection.subscribe(channelName, data);
  }

  /// Unsubscribe a channel using channel name
  void unsubscribe(String channelName) {
    _connection.unsubscribe(channelName);
  }
}
