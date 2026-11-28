import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'src/discovery.dart';
import 'src/colors.dart';
import 'src/receiver.dart';
import 'src/remote.dart';

void main() => runApp(const StickRemoteApp());

class StickRemoteApp extends StatelessWidget {
  const StickRemoteApp({super.key, this.home});
  final Widget? home;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'StickRemote',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: appBackground,
      colorScheme: ColorScheme.fromSeed(
        seedColor: deviceLink,
        brightness: Brightness.dark,
      ).copyWith(primary: deviceLink, surface: surface),
      appBarTheme: const AppBarTheme(
        backgroundColor: appBackground,
        centerTitle: false,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: home ?? const DevicePage(),
  );
}

enum _Page { devices, connecting, pin, remote }

class DevicePage extends StatefulWidget {
  const DevicePage({
    super.key,
    this.discovery,
    this.pairings,
    this.receiverFor,
  });
  final Discovery? discovery;
  final Pairings? pairings;
  final Receiver Function(Stick)? receiverFor;
  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  late final _discovery = widget.discovery ?? Discovery();
  late final _pairings = widget.pairings ?? Pairings();
  final _devices = <String, Stick>{};
  final _pin = TextEditingController();
  StreamSubscription<Stick>? _search;
  Receiver? _receiver;
  var _page = _Page.devices;
  var _generation = 0;
  var _scanning = false, _verifying = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _pairings.load();
    } catch (_) {
      _message =
          'Saved pairings could not be read. Select a Fire TV to pair again.';
    }
    if (mounted && _generation == 0) _scan(auto: true);
  }

  bool current(int id) => mounted && _generation == id;

  void _scan({bool auto = false}) {
    final id = ++_generation;
    _search?.cancel();
    setState(() {
      _page = _Page.devices;
      _receiver = null;
      _devices.clear();
      _scanning = true;
      if (!auto) _message = null;
    });
    _search = _discovery.scan().listen(
      (s) {
        if (!current(id)) return;
        setState(() => _devices[s.id] = s);
        if (auto && _pairings.last == s.id) _connect(s);
      },
      onError: (Object e) {
        if (current(id)) {
          setState(
            () => _message =
                'Discovery is unavailable. Check local network access or enter the TV address.',
          );
        }
      },
      onDone: () {
        if (!current(id)) return;
        setState(() => _scanning = false);
        final previous = _pairings.previous;
        if (auto && previous != null && previous.id.startsWith('ip:')) {
          _connect(previous);
        }
      },
    );
  }

  Future<void> _connect(Stick s) async {
    if (_page == _Page.connecting && _receiver != null) return;
    final id = ++_generation;
    unawaited(_search?.cancel());
    if (!current(id)) return;
    final tv = widget.receiverFor?.call(s) ?? Receiver(s);
    setState(() {
      _scanning = false;
      _message = null;
      _verifying = false;
      _receiver = tv;
      _page = _Page.connecting;
      _pin.clear();
    });
    try {
      await tv.wake();
      if (!current(id)) return;
      tv.token = _pairings.token(s);
      if (tv.token != null) {
        try {
          await tv.check();
          if (!current(id)) return;
          await _openPairedRemote(tv, id);
          return;
        } on ReceiverError catch (e) {
          if (e.status != 403 && e.status != 401) rethrow;
        }
      }
      if (!current(id)) return;
      await tv.displayPin();
      if (current(id)) setState(() => _page = _Page.pin);
    } catch (e) {
      if (current(id)) {
        setState(() {
          _page = _Page.devices;
          _devices[s.id] = s;
          _message = readableError(e);
        });
      }
    }
  }

  Future<void> _openPairedRemote(Receiver tv, int id) async {
    var saved = true;
    try {
      await _pairings.remember(tv.stick, tv.token!);
    } catch (_) {
      saved = false;
    }
    if (!mounted || _generation != id) return;
    setState(() => _page = _Page.remote);
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Connected. Could not save this pairing on your phone.',
          ),
        ),
      );
    }
  }

  Future<void> _verify() async {
    if (_page != _Page.pin || _verifying || _pin.text.length != 4) return;
    final tv = _receiver!, id = _generation;
    setState(() {
      _verifying = true;
      _message = null;
    });
    try {
      await tv.verify(_pin.text);
      if (current(id)) await _openPairedRemote(tv, id);
    } catch (e) {
      if (current(id)) {
        setState(() {
          final rejected =
              e is ReceiverError && [400, 401, 403].contains(e.status);
          if (rejected) _pin.clear();
          _message = rejected
              ? 'Check the four digits on your TV and try again.'
              : readableError(e);
        });
      }
    } finally {
      if (current(id)) setState(() => _verifying = false);
    }
  }

  Future<void> _manual() async {
    final id = ++_generation;
    unawaited(_search?.cancel());
    if (!mounted || id != _generation) return;
    setState(() => _scanning = false);
    final ip = await showDialog<String>(
      context: context,
      builder: (_) => const _AddressDialog(),
    );
    if (!current(id)) return;
    if (ip == null) {
      _scan();
      return;
    }
    setState(() {
      _message = null;
      _page = _Page.connecting;
      _receiver = null;
    });
    try {
      final s = await _discovery.manual(ip);
      if (current(id)) await _connect(s);
    } catch (e) {
      if (current(id)) {
        setState(() {
          _page = _Page.devices;
          _message = readableError(e);
        });
      }
    }
  }

  void _backToDevices() {
    if (_page == _Page.pin && !_verifying) {
      _receiver!
          .request('FireTV/pin/verify', post: true, body: {'pin': '-1'})
          .ignore();
    }
    _scan();
  }

  @override
  void dispose() {
    _generation++;
    _search?.cancel();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _page == _Page.devices,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToDevices();
      },
      child: Scaffold(
        backgroundColor: _page == _Page.remote ? panel : null,
        appBar: _page == _Page.remote
            ? null
            : AppBar(
                titleSpacing: 22,
                title: Row(
                  children: [
                    Image.asset(
                      'assets/stickremote-mark.png',
                      width: 25,
                      height: 28,
                      filterQuality: FilterQuality.high,
                      excludeFromSemantics: true,
                    ),
                    const SizedBox(width: 9),
                    Text(
                      'StickRemote',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.8,
                      ),
                    ),
                  ],
                ),
                actions: [
                  if (_page != _Page.devices)
                    IconButton(
                      onPressed: _backToDevices,
                      tooltip: 'Choose Fire TV',
                      icon: const Icon(Icons.connected_tv_rounded),
                    ),
                  const SizedBox(width: 10),
                ],
              ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: switch (_page) {
                _Page.devices => _picker(),
                _Page.connecting => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 22),
                    Text(
                      'Connecting to ${_receiver?.stick.name ?? 'Fire TV'}…',
                    ),
                    TextButton(
                      onPressed: _backToDevices,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
                _Page.pin => _pair(),
                _Page.remote => RemoteFace(
                  key: ValueKey(_receiver),
                  tv: _receiver!,
                  pairings: _pairings,
                  onChoose: _backToDevices,
                  onUnauthorized: () => _connect(_receiver!.stick),
                ),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _picker() => ListView(
    padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
    children: [
      const Align(alignment: Alignment.centerLeft, child: _TvBadge()),
      const SizedBox(height: 24),
      Text(
        'Connect to Fire TV',
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      const Text(
        'Choose a Fire TV on the same Wi-Fi network.',
        style: TextStyle(color: Colors.white70, fontSize: 16),
      ),
      const SizedBox(height: 32),
      Row(
        children: [
          if (_scanning)
            const Padding(
              padding: EdgeInsets.only(right: 10),
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Expanded(
            child: Text(
              _scanning
                  ? 'Searching for devices…'
                  : _devices.isEmpty
                  ? 'No Fire TVs found'
                  : 'Available devices',
            ),
          ),
          IconButton(
            onPressed: () => _scan(),
            tooltip: 'Scan again',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      for (final s in _devices.values)
        Card(
          color: surface,
          child: ListTile(
            leading: const Icon(Icons.tv_rounded),
            title: Text(s.name),
            subtitle: Text(s.host),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _connect(s),
          ),
        ),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(_message!, style: const TextStyle(color: deviceLink)),
        ),
      const Divider(height: 32),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _manual,
          icon: const Icon(Icons.add),
          label: const Text('Enter TV address'),
        ),
      ),
    ],
  );

  Widget _pair() => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
    children: [
      const Align(alignment: Alignment.centerLeft, child: _TvBadge()),
      const SizedBox(height: 24),
      Text(
        'Pair with ${_receiver!.stick.name}',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 8),
      const Text('Enter the four digits shown on your TV.'),
      const SizedBox(height: 24),
      TextField(
        controller: _pin,
        autofocus: true,
        keyboardType: TextInputType.number,
        maxLength: 4,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontSize: 30, letterSpacing: 12),
        enabled: !_verifying,
        decoration: const InputDecoration(
          labelText: 'Pairing PIN',
          counterText: '',
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _verify(),
      ),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_message!, style: const TextStyle(color: deviceLink)),
        ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: _verifying || _pin.text.length != 4 ? null : _verify,
        child: Text(_verifying ? 'Pairing…' : 'Pair remote'),
      ),
    ],
  );
}

class _TvBadge extends StatelessWidget {
  const _TvBadge();
  @override
  Widget build(BuildContext context) => Container(
    width: 76,
    height: 76,
    decoration: BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(24),
    ),
    child: const Icon(Icons.connected_tv_rounded, color: deviceLink, size: 36),
  );
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();
  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  String value = '';
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Fire TV address'),
    content: TextField(
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(
        labelText: 'IPv4 address',
        hintText: '192.168.1.20',
      ),
      onChanged: (s) => setState(() => value = s),
      onSubmitted: (s) => Navigator.pop(context, s),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: value.trim().isEmpty
            ? null
            : () => Navigator.pop(context, value),
        child: const Text('Connect'),
      ),
    ],
  );
}
