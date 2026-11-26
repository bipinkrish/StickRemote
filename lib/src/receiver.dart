import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'discovery.dart';

const bridge = MethodChannel('stickremote/receiver');

class ReceiverError implements Exception {
  const ReceiverError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

String readableError(Object error) {
  if (error is HttpException) return error.message;
  if (error is ReceiverError) return error.message;
  if (error is FormatException) return error.message;
  if (error is PlatformException && error.message != null) {
    return error.message!;
  }
  return 'Could not reach the Fire TV. Check that both devices are on the same Wi-Fi.';
}

enum AudioControl {
  volume('volumeSupport', 'volumeWorks', 'volume_up', 'Try Volume Up'),
  mute('muteSupport', 'muteWorks', 'mute', 'Try Mute');

  const AudioControl(
    this.property,
    this.storageKey,
    this.command,
    this.testLabel,
  );
  final String property, storageKey, command, testLabel;
}

class Pairings {
  Map<String, dynamic> _devices = {};
  String? last;
  Future<void> _pendingWrite = Future.value();
  Future<void> load() async {
    final saved = await bridge.invokeMethod<String>('read');
    if (saved == null) return;
    final data = jsonDecode(saved) as Map<String, dynamic>;
    _devices = Map<String, dynamic>.from(data['devices'] as Map);
    last = data['last'];
  }

  String? token(Stick s) => _devices[s.id]?['token'];
  bool? audioResult(Stick stick, AudioControl control) =>
      _devices[stick.id]?[control.storageKey] as bool?;
  Stick? get previous =>
      _devices[last] == null ? null : Stick.fromJson(_devices[last]);
  Future<void> remember(Stick stick, String token) =>
      _update(stick, {...stick.toJson(), 'token': token}, select: true);

  Future<void> saveAudioResult(Stick stick, AudioControl control, bool works) =>
      _update(stick, {control.storageKey: works});

  Future<void> _update(
    Stick stick,
    Map<String, dynamic> changes, {
    bool select = false,
  }) {
    final write = _pendingWrite.then((_) async {
      final next = {
        ..._devices,
        stick.id: {...?_devices[stick.id] as Map?, ...changes},
      };
      final selected = select ? stick.id : last;
      await bridge.invokeMethod(
        'write',
        jsonEncode({'devices': next, 'last': selected}),
      );
      _devices = next;
      last = selected;
    });
    _pendingWrite = write.catchError((Object _) {});
    return write;
  }
}

class Receiver {
  Receiver(this.stick);
  final Stick stick;
  String? token;
  Map<String, String> get headers => {
    'Content-Type': 'application/json; charset=utf-8',
    'x-api-key': '0987654321',
    'x-amzn-request-id': const Uuid().v4(),
    if (token != null) 'x-client-token': token!,
  };

  Future<String> request(
    String path, {
    bool post = false,
    Map<String, dynamic>? body,
  }) async {
    final res = await bridge.invokeMapMethod<String, dynamic>('request', {
      'host': stick.host,
      'path': '/v1/$path',
      'headers': headers,
      'method': post ? 'POST' : 'GET',
      if (body != null) 'body': jsonEncode(body),
    });
    final status = res!['status'] as int;
    if (status < 200 || status >= 300) {
      throw ReceiverError(status, switch (status) {
        401 || 403 => 'Fire TV declined this pairing.',
        429 => 'Too many attempts. Wait a moment and try again.',
        404 || 405 || 501 => 'This Fire TV does not support that control.',
        _ => 'Fire TV returned an error ($status).',
      });
    }
    return res['body'] as String;
  }

  Future<void> wake() async {
    await Discovery.wake(stick);
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  Future<void> check() async {
    try {
      await request('FireTV/status');
    } on ReceiverError catch (e) {
      if (e.status != 405) rethrow;
      await request('FireTV');
    }
  }

  Future<void> displayPin() async {
    token = null;
    await request(
      'FireTV/pin/display',
      post: true,
      body: {'friendlyName': 'StickRemote'},
    );
  }

  Future<String> verify(String pin) async {
    final response = await request(
      'FireTV/pin/verify',
      post: true,
      body: {'pin': pin},
    );
    final data = jsonDecode(response);
    final value = data is Map ? data['description'] : null;
    if (value is! String || value.isEmpty) {
      throw const ReceiverError(403, 'Check the PIN on your TV and try again.');
    }
    token = value;
    return value;
  }

  Future<void> command(String id, {String? phase}) async {
    final audio = const {'volume_up', 'volume_down', 'mute'}.contains(id);
    try {
      await request(
        'FireTV?action=$id',
        post: true,
        body: phase == null ? null : {'keyActionType': phase},
      );
      if (audio && kDebugMode) {
        debugPrint('StickRemote: $id ${phase ?? 'tap'} acknowledged');
      }
    } on PlatformException catch (error) {
      if (!audio || error.code != 'connection') rethrow;
      if (kDebugMode) {
        debugPrint(
          'StickRemote: $id ${phase ?? 'tap'} failed (${error.details})',
        );
      }
      throw const ReceiverError(
        0,
        'No reply to the audio command. Check whether volume works with your Fire TV equipment setup.',
      );
    } on ReceiverError catch (error) {
      if (audio && kDebugMode) {
        debugPrint(
          'StickRemote: $id ${phase ?? 'tap'} returned HTTP ${error.status}',
        );
      }
      rethrow;
    }
  }

  Future<void> media(String id) async {
    if (id == 'play') {
      await request('media?action=play', post: true);
    } else {
      await request(
        'media?action=scan',
        post: true,
        body: {'direction': id, 'durationInSeconds': '10', 'speed': '1'},
      );
    }
  }

  Future<void> text(String value) async {
    await request('FireTV/keyboard', post: true, body: {'text': value});
  }

  Future<void> openVoice() async {
    await request('FireTV/voiceCommand?action=start', post: true);
    try {
      await bridge
          .invokeMethod('openVoice', {'host': stick.host, 'headers': headers})
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      await closeVoice();
      rethrow;
    }
  }

  Future<void> audio(Uint8List data) => bridge.invokeMethod('audio', data);
  Future<void> closeVoice() async {
    try {
      await bridge.invokeMethod('closeVoice');
    } finally {
      await request('FireTV/voiceCommand?action=stop', post: true);
    }
  }
}
