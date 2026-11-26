import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stickremote/main.dart';
import 'package:stickremote/src/discovery.dart';
import 'package:stickremote/src/receiver.dart';
import 'package:stickremote/src/remote.dart';

final tv = Stick(
  'uuid:lounge',
  'Living room',
  '192.168.1.20',
  Uri.parse('http://192.168.1.20:8009/apps/FireTVRemote'),
);

class LocalDiscovery extends Discovery {
  @override
  Stream<Stick> scan() => Stream.value(tv);
}

class AwakeReceiver extends Receiver {
  AwakeReceiver(super.stick);
  @override
  Future<void> wake() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('SSDP description URL must belong to the sender', () {
    const address = '192.168.1.20';
    final url = Discovery.descriptionLocation(
      'HTTP/1.1 200 OK\r\nlOcAtIoN: http://$address:60000/desc.xml\r\n',
      address,
    );
    expect(url?.path, '/desc.xml');
    expect(
      Discovery.descriptionLocation(
        'HTTP/1.1 200 OK\r\nLOCATION: http://different.test/\r\n',
        address,
      ),
      isNull,
    );
  });
  for (final (reported, control) in [
    ('Supported', 'Volume up'),
    ('NotSupported', 'Volume and mute unavailable'),
    ('MaybeSupported', 'Volume setup'),
  ]) {
    testWidgets('Volume support: $reported', (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(bridge, (call) async {
        expect(call.method, 'request');
        expect(call.arguments['path'], '/v1/FireTV/properties');
        return {
          'status': 200,
          'body': jsonEncode({
            'volumeSupport': reported,
            'muteSupport': reported,
          }),
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(bridge, null));
      await tester.pumpWidget(
        StickRemoteApp(
          home: Scaffold(
            body: RemoteFace(
              tv: Receiver(tv),
              pairings: Pairings(),
              onChoose: () {},
              onUnauthorized: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(control), findsOneWidget);
      expect(find.text('TV brand'), findsNothing);
    });
  }
  testWidgets('discover, pair, control volume and reconnect after relaunch', (
    tester,
  ) async {
    String? storage;
    final paths = <String>[];
    final phases = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(bridge, (call) async {
      if (call.method == 'read') return storage;
      if (call.method == 'write') {
        storage = call.arguments as String;
        return null;
      }
      final args = Map.from(call.arguments as Map);
      final path = args['path'] as String;
      paths.add(path);
      var body = '{}';
      if (path.endsWith('/pin/verify')) {
        expect(jsonDecode(args['body']), {'pin': '0123'});
        body = '{"description":"test-token"}';
      } else if (path.endsWith('/pin/display')) {
        expect(args['headers']['x-client-token'], isNull);
      } else {
        expect(args['headers']['x-client-token'], 'test-token');
      }
      if (path.endsWith('action=volume_up')) {
        phases.add(
          args['body'] == null
              ? 'tap'
              : jsonDecode(args['body'])['keyActionType'],
        );
      }
      return {'status': 200, 'body': body};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(bridge, null));
    Widget app() => StickRemoteApp(
      home: DevicePage(
        discovery: LocalDiscovery(),
        receiverFor: AwakeReceiver.new,
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Living room'));
    await tester.pumpAndSettle();
    expect(
      find.byType(TextField),
      findsOneWidget,
      reason:
          tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data)
              .join(' / ') +
          paths.toString(),
    );
    await tester.enterText(find.byType(TextField), '0123');
    await tester.pump();
    await tester.tap(find.text('Pair remote'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Select'), findsOneWidget);
    for (final (label, command) in [
      ('Up', 'dpad_up'),
      ('Right', 'dpad_right'),
      ('Down', 'dpad_down'),
      ('Left', 'dpad_left'),
      ('Select', 'select'),
    ]) {
      await tester.tap(find.bySemanticsLabel(label));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        paths.where((path) => path.endsWith('action=$command')),
        hasLength(2),
      );
    }
    expect(find.bySemanticsLabel('Mute'), findsNothing);
    await tester.ensureVisible(find.text('Volume setup'));
    await tester.tap(find.text('Volume setup'));
    await tester.pumpAndSettle();
    expect(find.text('Try Mute'), findsOneWidget);
    expect(
      paths.where(
        (path) =>
            path.endsWith('action=mute') || path.endsWith('action=volume_up'),
      ),
      isEmpty,
    );

    await tester.tap(find.text('Try Volume Up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No change'));
    await tester.pumpAndSettle();
    expect(find.text('TV volume setup'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LG').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('SIMPLINK'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Try Volume Up'), findsNothing);
    await tester.ensureVisible(find.text('Volume setup'));
    await tester.tap(find.text('Volume setup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try Volume Up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(find.text('Try Volume Up'), findsNothing);
    await tester.tap(find.text('Try Mute'));
    await tester.pumpAndSettle();
    expect(find.text('Did the TV mute or unmute?'), findsOneWidget);
    await tester.tap(find.text('No change'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Volume up'), findsOneWidget);
    expect(find.bySemanticsLabel('Mute'), findsNothing);
    await tester.ensureVisible(find.text('Volume setup'));
    await tester.tap(find.text('Volume setup'));
    await tester.pumpAndSettle();
    expect(find.text('Try Volume Up'), findsNothing);
    await tester.tap(find.text('Try Mute'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(paths.where((path) => path.endsWith('action=mute')), hasLength(2));
    expect(find.bySemanticsLabel('Mute'), findsOneWidget);
    expect(find.text('Volume setup'), findsNothing);
    expect(phases, ['tap', 'tap']);
    phases.clear();
    await tester.ensureVisible(find.bySemanticsLabel('Volume up'));
    await tester.tap(find.bySemanticsLabel('Volume up'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(phases, ['tap']);
    await tester.longPress(find.bySemanticsLabel('Volume up'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(phases, ['tap', 'keyDown', 'keyUp']);
    expect(storage, contains('uuid:lounge'));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Select'), findsOneWidget);
    expect(paths.where((p) => p.endsWith('/pin/display')), hasLength(1));
    expect(find.bySemanticsLabel('Volume up'), findsOneWidget);
    expect(find.text('Try Volume Up'), findsNothing);
    expect(paths, contains('/v1/FireTV/status'));
  });
}
