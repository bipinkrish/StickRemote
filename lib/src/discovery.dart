import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

class Stick {
  const Stick(this.id, this.name, this.host, this.dial);
  final String id;
  final String name;
  final String host;
  final Uri dial;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'dial': dial.toString(),
  };

  static Stick fromJson(Map<String, dynamic> map) =>
      Stick(map['id'], map['name'], map['host'], Uri.parse(map['dial']));
}

const _search =
    'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
    'MAN: "ssdp:discover"\r\nMX: 1\r\nST: urn:dial-multiscreen-org:service:dial:1\r\n\r\n';

class Discovery {
  static Uri? descriptionLocation(String reply, String host) {
    final lines = reply.split('\r\n');
    if (!RegExp(r'^HTTP/1\.[01] 200\b').hasMatch(lines.first)) return null;
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon < 1 ||
          line.substring(0, colon).trim().toLowerCase() != 'location') {
        continue;
      }
      final url = Uri.tryParse(line.substring(colon + 1).trim());
      if (url != null &&
          url.scheme == 'http' &&
          url.host == host &&
          url.userInfo.isEmpty) {
        return url;
      }
    }
    return null;
  }

  static Future<({int status, String body, String? apps})> _http(
    Uri uri, {
    bool start = false,
  }) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      return await (() async {
        final req = await client.openUrl(start ? 'POST' : 'GET', uri);
        req.followRedirects = false;
        if (start) {
          req.headers.contentType = ContentType.text;
          req.contentLength = 0;
        }
        final res = await req.close();
        final bytes = <int>[];
        await for (final part in res) {
          if (bytes.length + part.length > 256 * 1024) {
            throw const FormatException('Device description is too large.');
          }
          bytes.addAll(part);
        }
        return (
          status: res.statusCode,
          body: utf8.decode(bytes, allowMalformed: true),
          apps: res.headers.value('application-url'),
        );
      })().timeout(const Duration(seconds: 3));
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> wake(Stick stick) async {
    final reply = await _http(stick.dial, start: true);
    if (reply.status >= 400) {
      throw const HttpException('Fire TV could not start the remote service.');
    }
  }

  Future<Stick?> identifyResponse(String reply, String host) async {
    final location = descriptionLocation(reply, host);
    if (location == null) return null;
    final info = await _http(location);
    if (info.status != 200) return null;
    final doc = XmlDocument.parse(info.body);
    String? field(String name) => doc.descendantElements
        .where((element) => element.name.local == name)
        .firstOrNull
        ?.innerText
        .trim();
    final id = field('UDN');
    if (id == null || id.isEmpty) return null;
    final base = Uri.tryParse(info.apps ?? 'http://$host:8009/apps/');
    if (base == null ||
        base.scheme != 'http' ||
        base.host != host ||
        base.userInfo.isNotEmpty ||
        !{8009, 8019}.contains(base.port)) {
      return null;
    }
    final dial = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/FireTVRemote',
    );
    final probe = await _http(dial);
    if (probe.status >= 400) return null;
    return Stick(id, field('friendlyName') ?? 'Fire TV', host, dial);
  }

  Future<Stick> manual(String input) async {
    final ip = InternetAddress.tryParse(input.trim());
    if (ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        ip.isMulticast ||
        ip.isLoopback ||
        ip.address == '0.0.0.0' ||
        ip.address == '255.255.255.255') {
      throw const FormatException(
        'Enter the IPv4 address shown on your Fire TV.',
      );
    }
    for (final port in [8009, 8019]) {
      final dial = Uri.http('${ip.address}:$port', '/apps/FireTVRemote');
      try {
        if ((await _http(dial)).status < 400) {
          return Stick('ip:${ip.address}', 'Fire TV', ip.address, dial);
        }
      } on Exception {
        continue;
      }
    }
    throw const HttpException('No Fire TV answered at that address.');
  }

  Stream<Stick> scan() {
    late final StreamController<Stick> results;
    RawDatagramSocket? socket;
    Timer? repeat, end;
    var stopped = false;
    final pending = <String>{};
    final found = <String>{};
    void stop() {
      stopped = true;
      repeat?.cancel();
      end?.cancel();
      socket?.close();
    }

    Future<void> examine(Datagram packet) async {
      final host = packet.address.address;
      if (found.contains(host) || !pending.add(host)) {
        return;
      }
      try {
        final stick = await identifyResponse(latin1.decode(packet.data), host);
        if (!stopped && stick != null) {
          found.add(host);
          results.add(stick);
        }
      } on Exception {
        // Other DIAL services can disappear or return unrelated descriptions.
      } finally {
        pending.remove(host);
      }
    }

    void finish([Object? error]) {
      if (stopped) return;
      stop();
      if (error != null) results.addError(error);
      unawaited(results.close());
    }

    Future<void> start() async {
      try {
        final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        if (stopped) {
          udp.close();
          return;
        }
        socket = udp;
        udp.listen((event) {
          if (event != RawSocketEvent.read) return;
          Datagram? packet;
          while ((packet = udp.receive()) != null) {
            unawaited(examine(packet!));
          }
        }, onError: finish);
        void search() {
          try {
            udp.send(
              ascii.encode(_search),
              InternetAddress('239.255.255.250'),
              1900,
            );
          } on SocketException catch (e) {
            finish(e);
          }
        }

        end = Timer(const Duration(seconds: 7), finish);
        repeat = Timer.periodic(const Duration(seconds: 1), (_) => search());
        search();
      } catch (e) {
        finish(e);
      }
    }

    results = StreamController<Stick>(onListen: start, onCancel: stop);
    return results.stream;
  }
}
