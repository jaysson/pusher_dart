# Pusher
Unofficial pusher client for dart.

## Usage
Using this package is similar to how one would use PusherJS.

### Initialize and connect
```dart
import 'package:pusher_dart';

final pusher = Pusher(
    DotEnv().env['PUSHER_APP_KEY'],
    PusherOptions(
        authEndpoint: DotEnv().env['PUSHER_AUTH_URL'],
        auth: PusherAuth(headers: {
          'Authorization': 'Bearer $apiToken',
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        })
    )
);
```
### Subscribe to a channel
```dart
final channel = pusher.subscribe('my-channel');
```

### Bind to events
```dart
eventHandler(Object data) async {
    final jsonData = Map<String, Object>.from(jsonDecode(data));
}

channel.bind('my-event', eventHandler);
```

### Trigger event on a channel
You can pass any data that can be converted to JSON using `jsonEncode(data);`.  
```dart
Map<String, String> jsonData = {};
channel.trigger('my-event', jsonData);
```

### Close the connection
```dart
pusher.disconnect();
```