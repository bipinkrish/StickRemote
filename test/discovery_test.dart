import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:stickremote/src/discovery.dart';

void main() {
  test('receiver description, DIAL probe and DIAL launch over loopback', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8019);
    addTearDown(() => server.close(force: true));
    final calls = <String>[];
    server.listen((request) async {
      calls.add('${request.method} ${request.uri.path}');
      if (request.uri.path == '/description') {
        request.response.headers.set(
          'Application-URL',
          'http://127.0.0.1:8019/dial/apps/',
        );
        request.response.write(
          '<root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
          '<friendlyName>Bedroom &amp; TV</friendlyName><UDN>uuid:bedroom</UDN></device></root>',
        );
      } else if (request.uri.path == '/dial/apps/FireTVRemote') {
        request.response.statusCode = request.method == 'POST' ? 201 : 200;
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    final device = await Discovery().identifyResponse(
      'HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:8019/description\r\n\r\n',
      '127.0.0.1',
    );
    expect(device?.name, 'Bedroom & TV');
    expect(device?.id, 'uuid:bedroom');
    await Discovery.wake(device!);
    expect(calls, [
      'GET /description',
      'GET /dial/apps/FireTVRemote',
      'POST /dial/apps/FireTVRemote',
    ]);
  });
}
