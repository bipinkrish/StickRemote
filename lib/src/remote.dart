import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'colors.dart';
import 'receiver.dart';
import 'pad_geometry.dart';
import 'volume_setup.dart';

class RemoteFace extends StatefulWidget {
  const RemoteFace({
    super.key,
    required this.tv,
    required this.pairings,
    required this.onChoose,
    required this.onUnauthorized,
  });
  final Receiver tv;
  final Pairings pairings;
  final VoidCallback onChoose, onUnauthorized;
  @override
  State<RemoteFace> createState() => _RemoteFaceState();
}

class _RemoteFaceState extends State<RemoteFace> with WidgetsBindingObserver {
  Future<void> _commands = Future.value();
  bool _pad = true, _power = true;
  final _reportedAudio = <AudioControl, bool?>{};
  bool _loadingCapabilities = true, _testingVolume = false;
  bool _holding = false,
      _voiceBusy = false,
      _recording = false,
      _unauthorized = false;
  Completer<void>? _release;
  Offset _drag = Offset.zero;
  final _holds = <String, DateTime>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _capabilities();
  }

  Future<void> _capabilities() async {
    try {
      final data = jsonDecode(await widget.tv.request('FireTV/properties'));
      if (mounted && data is Map) {
        for (final control in AudioControl.values) {
          _reportedAudio[control] = switch (data[control.property]) {
            'Supported' => true,
            'NotSupported' => false,
            _ => null,
          };
        }
        _power = data['powerSupport'] != 'NotSupported';
      }
    } on Exception {
      // Some paired receivers deny this optional endpoint but accept commands.
    } finally {
      if (mounted) setState(() => _loadingCapabilities = false);
    }
  }

  bool? _audioWorks(AudioControl control) =>
      _reportedAudio[control] ??
      widget.pairings.audioResult(widget.tv.stick, control);

  List<AudioControl> get _untestedAudio => [
    for (final control in AudioControl.values)
      if (_reportedAudio[control] != false && _audioWorks(control) != true)
        control,
  ];

  Future<void> _openAudioSetup() async {
    if (_testingVolume) return;
    setState(() => _testingVolume = true);
    try {
      while (true) {
        if (!mounted) return;
        final controls = _untestedAudio;
        if (controls.isEmpty) return;
        final selected = await showDialog<AudioControl>(
          context: context,
          builder: (_) => VolumeSetupHelp(
            controls: controls,
            showHelp: controls.any((c) => _audioWorks(c) == false),
          ),
        );
        if (selected == null || !mounted) return;
        await _commands;
        if (!mounted || _unauthorized) return;
        await widget.tv.command(selected.command);
        if (!mounted) return;
        final mute = selected == AudioControl.mute;
        final works = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              mute ? 'Did the TV mute or unmute?' : 'Did the TV volume change?',
            ),
            content: Text(
              mute
                  ? 'Listen for the sound to switch off or on, or check the mute indicator on your TV.'
                  : 'Listen for a change or check the volume indicator on your TV.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('No change'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Yes'),
              ),
            ],
          ),
        );
        if (works == null || !mounted) return;
        await widget.pairings.saveAudioResult(widget.tv.stick, selected, works);
        if (mounted) setState(() {});
      }
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _testingVolume = false);
    }
  }

  void _error(Object e) {
    if (!mounted || _unauthorized) return;
    if (e is ReceiverError && [401, 403].contains(e.status)) {
      _unauthorized = true;
      widget.onUnauthorized();
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(readableError(e))));
  }

  void _send(Future<void> Function(Receiver) action) {
    final tv = widget.tv;
    _commands = _commands.then((_) async {
      if (_unauthorized) return;
      try {
        await action(tv);
      } catch (e) {
        _error(e);
      }
    });
  }

  void _down(String id) {
    if (_holds.containsKey(id)) return;
    _holds[id] = DateTime.now();
    HapticFeedback.selectionClick();
    _send((tv) => tv.command(id, phase: 'keyDown'));
  }

  void _up(String id) {
    final started = _holds.remove(id);
    if (started == null) return;
    // Preserve short taps even when both pointer events arrive in the same frame.
    final wait =
        const Duration(milliseconds: 200) - DateTime.now().difference(started);
    _send((tv) async {
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      await tv.command(id, phase: 'keyUp');
    });
  }

  void _tap(String id) {
    _down(id);
    _up(id);
  }

  Future<void> _keyboard() async {
    var initial = '', replace = false;
    try {
      final info = jsonDecode(await widget.tv.request('FireTV/keyboard'));
      if (info is Map) {
        initial = info['text'] as String? ?? '';
        replace = true;
      }
    } on ReceiverError catch (e) {
      if (![404, 405, 501].contains(e.status)) {
        _error(e);
        return;
      }
    } catch (e) {
      _error(e);
      return;
    }
    if (!mounted) return;
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _KeyboardDialog(initial: initial, replace: replace),
    );
    if (value == null || !mounted) return;
    _send((tv) async {
      if (replace) {
        await tv.text(value);
      } else {
        await tv.request('FireTV/text', post: true, body: {'text': value});
      }
    });
  }

  Future<void> _voiceStart() async {
    if (_voiceBusy) return;
    _voiceBusy = true;
    _holding = true;
    final done = _release = Completer<void>();
    final tv = widget.tv;
    final recorder = AudioRecorder();
    var connected = false;
    StreamSubscription<void>? audio;
    try {
      if (!await recorder.hasPermission()) {
        throw const ReceiverError(
          0,
          'Microphone permission is needed for voice search.',
        );
      }
      if (!_holding) return;
      await tv.openVoice();
      connected = true;
      if (!_holding) return;
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      if (!_holding) return;
      if (mounted) setState(() => _recording = true);
      audio = stream
          .asyncMap((data) async {
            if (_holding) await tv.audio(data);
          })
          .listen(
            (_) {},
            onError: (Object e) {
              _error(e);
              _voiceEnd();
            },
            onDone: _voiceEnd,
          );
      await done.future;
    } catch (e) {
      _error(e);
    } finally {
      _holding = false;
      try {
        await audio?.cancel();
        await recorder.dispose();
      } catch (e) {
        _error(e);
      }
      if (connected) {
        try {
          await tv.closeVoice();
        } catch (e) {
          _error(e);
        }
      }
      _release = null;
      _voiceBusy = false;
      if (mounted) setState(() => _recording = false);
    }
  }

  void _voiceEnd() {
    _holding = false;
    if (_release?.isCompleted == false) _release!.complete();
  }

  void _releaseAll() {
    _voiceEnd();
    for (final id in _holds.keys.toList()) {
      _up(id);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _releaseAll();
    }
  }

  @override
  void dispose() {
    _releaseAll();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget _button(
    String label,
    IconData icon,
    VoidCallback? pressed, {
    String? hold,
  }) {
    final body = Container(
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(32),
      ),
      child: Icon(
        icon,
        size: 22,
        color: pressed == null ? Colors.white24 : Colors.white,
      ),
    );
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Semantics(
          label: label,
          button: true,
          enabled: pressed != null,
          onTap: pressed,
          child: ExcludeSemantics(
            child: GestureDetector(
              onTap: pressed,
              onLongPressStart: hold == null || pressed == null
                  ? null
                  : (_) => _down(hold),
              onLongPressEnd: hold == null || pressed == null
                  ? null
                  : (_) => _up(hold),
              onLongPressCancel: hold == null || pressed == null
                  ? null
                  : () => _up(hold),
              child: body,
            ),
          ),
        ),
      ),
    );
  }

  Widget _touchpad() => Semantics(
    label: 'Touchpad. Swipe to move or tap to select.',
    button: true,
    onTap: () => _tap('select'),
    child: GestureDetector(
      onTap: () => _tap('select'),
      onLongPressStart: (_) => _down('select'),
      onLongPressEnd: (_) => _up('select'),
      onLongPressCancel: () => _up('select'),
      onPanStart: (_) => _drag = Offset.zero,
      onPanUpdate: (event) {
        _drag += event.delta;
        if (_drag.distance < 34) return;
        final dir = _drag.dx.abs() > _drag.dy.abs()
            ? (_drag.dx < 0 ? 'left' : 'right')
            : (_drag.dy < 0 ? 'up' : 'down');
        _tap('dpad_$dir');
        _drag = Offset.zero;
      },
      child: ClipPath(
        clipper: const _TouchpadClipper(),
        child: const ColoredBox(
          color: padFace,
          child: Center(
            child: Text(
              'Swipe to move,\ntap to select',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: padArrow,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _navigation() => AnimatedCrossFade(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200),
    firstCurve: Curves.easeInOut,
    secondCurve: Curves.easeInOut,
    crossFadeState: _pad ? CrossFadeState.showFirst : CrossFadeState.showSecond,
    layoutBuilder: (top, topKey, bottom, bottomKey) =>
        Stack(fit: StackFit.expand, children: [bottom, top]),
    firstChild: FittedBox(
      child: SizedBox.square(
        dimension: 327,
        child: Stack(
          children: [for (final segment in padSegments) _segment(segment)],
        ),
      ),
    ),
    secondChild: _touchpad(),
  );

  Widget _segment(PadSegment part) {
    final bounds = part.face.getBounds();
    final origin = -bounds.topLeft;
    final clipper = _SegmentClipper(part.face, origin);
    return Positioned.fromRect(
      rect: bounds,
      child: Semantics(
        button: true,
        label: part.label,
        onTap: () => _tap(part.command),
        child: ClipPath(
          clipper: clipper,
          child: Material(
            color: part.arrow == null ? surface : padFace,
            child: InkWell(
              excludeFromSemantics: true,
              highlightColor: controlIcon.withAlpha(100),
              onTapDown: (_) => _down(part.command),
              onTapUp: (_) => _up(part.command),
              onTapCancel: () => _up(part.command),
              onTap: () {},
              child: part.arrow == null
                  ? null
                  : ClipPath(
                      clipper: _SegmentClipper(part.arrow!, origin),
                      child: const ColoredBox(color: padArrow),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  void _home() => _send((tv) async {
    try {
      await tv.command('wakeup');
    } on Exception {
      // Some receivers are already awake.
    }
    await tv.command('home');
  });

  Widget _round(
    String label,
    IconData icon,
    VoidCallback? onTap, {
    double size = 48,
    double iconSize = 22,
    Color fill = surface,
  }) => IconButton.filled(
    tooltip: label,
    style: IconButton.styleFrom(
      padding: EdgeInsets.zero,
      fixedSize: Size.square(size),
      backgroundColor: fill,
      foregroundColor: controlIcon,
    ),
    iconSize: iconSize,
    icon: Icon(icon),
    onPressed: onTap,
  );

  Widget _microphone() => Semantics(
    button: true,
    label: 'Voice search',
    hint: 'Hold to speak',
    onTap: () {
      if (_holding) {
        _voiceEnd();
      } else {
        _voiceStart();
      }
    },
    child: ExcludeSemantics(
      child: GestureDetector(
        onLongPressStart: (_) => _voiceStart(),
        onLongPressEnd: (_) => _voiceEnd(),
        onLongPressCancel: _voiceEnd,
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hold the microphone to speak.')),
        ),
        child: CircleAvatar(
          radius: 24,
          backgroundColor: _recording ? deviceLink : surface,
          child: const Icon(
            Icons.mic_none_rounded,
            color: controlIcon,
            size: 22,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, space) {
      final volume = _audioWorks(AudioControl.volume) == true;
      final mute = _audioWorks(AudioControl.mute) == true;
      final needsSetup = !_loadingCapabilities && _untestedAudio.isNotEmpty;
      final extraRow = needsSetup && (volume || mute);
      final areaHeight = math.max(
        250.0,
        space.maxHeight - 292 - (extraRow ? 56 : 0),
      );
      final padSize = math.min(space.maxWidth - 32, areaHeight - 16);
      return SingleChildScrollView(
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  _round(
                    'TV power',
                    Icons.power_settings_new,
                    _power ? () => _send((tv) => tv.command('power')) : null,
                    iconSize: 24,
                    fill: Colors.transparent,
                  ),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: widget.onChoose,
                      icon: const Icon(Icons.tv, size: 18),
                      label: Text(
                        widget.tv.stick.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                  ),
                  _round(
                    _pad ? 'Use touchpad' : 'Use directional pad',
                    _pad ? Icons.touch_app_outlined : Icons.gamepad_outlined,
                    () => setState(() => _pad = !_pad),
                    iconSize: 24,
                    fill: Colors.transparent,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _round(
              'Menu',
              Icons.menu_rounded,
              () => _send((tv) => tv.command('menu')),
              size: 64,
              iconSize: 28,
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                height: areaHeight,
                child: Center(
                  child: SizedBox(
                    width: double.infinity,
                    height: math.min(areaHeight, padSize + 32),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Center(
                          child: SizedBox(
                            width: double.infinity,
                            height: padSize,
                            child: _navigation(),
                          ),
                        ),
                        Positioned(
                          left: 8,
                          top: 8,
                          child: _round(
                            'Keyboard',
                            Icons.keyboard_outlined,
                            _keyboard,
                          ),
                        ),
                        Positioned(right: 8, top: 8, child: _microphone()),
                        Positioned(
                          left: 8,
                          bottom: 8,
                          child: _round(
                            'Back',
                            Icons.arrow_back_rounded,
                            () => _send((tv) => tv.command('back')),
                            size: 64,
                            iconSize: 28,
                          ),
                        ),
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: _round(
                            'Home',
                            Icons.home_outlined,
                            _home,
                            size: 64,
                            iconSize: 28,
                            fill: homeOrange,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      _button(
                        'Rewind',
                        Icons.fast_rewind_rounded,
                        () => _send((tv) => tv.media('back')),
                      ),
                      _button(
                        'Play or pause',
                        Icons.play_arrow_rounded,
                        () => _send((tv) => tv.media('play')),
                      ),
                      _button(
                        'Fast forward',
                        Icons.fast_forward_rounded,
                        () => _send((tv) => tv.media('forward')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_loadingCapabilities)
                    const Center(
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (volume || mute)
                    Row(
                      children: [
                        if (mute)
                          _button(
                            'Mute',
                            Icons.volume_off_outlined,
                            () => _send((tv) => tv.command('mute')),
                          ),
                        if (volume) ...[
                          _button(
                            'Volume down',
                            Icons.volume_down_outlined,
                            () => _send((tv) => tv.command('volume_down')),
                            hold: 'volume_down',
                          ),
                          _button(
                            'Volume up',
                            Icons.volume_up_outlined,
                            () => _send((tv) => tv.command('volume_up')),
                            hold: 'volume_up',
                          ),
                        ],
                      ],
                    )
                  else if (!needsSetup)
                    const Text(
                      'Volume and mute unavailable',
                      style: TextStyle(color: Colors.white60),
                    ),
                  if (needsSetup) ...[
                    if (extraRow) const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: surface,
                            foregroundColor: controlIcon,
                            shape: const StadiumBorder(),
                          ),
                          onPressed: _testingVolume ? null : _openAudioSetup,
                          icon: const Icon(Icons.volume_up_outlined, size: 22),
                          label: const Text('Volume setup'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _SegmentClipper extends CustomClipper<Path> {
  const _SegmentClipper(this.path, this.offset);
  final Path path;
  final Offset offset;
  @override
  Path getClip(Size size) => path.shift(offset);
  @override
  bool shouldReclip(_SegmentClipper old) =>
      old.path != path || old.offset != offset;
}

// The two pairs of corner keys sit in 64 and 80 dp cutouts.
class _TouchpadClipper extends CustomClipper<Path> {
  const _TouchpadClipper();
  @override
  Path getClip(Size size) {
    final w = size.width, h = size.height;
    final top = math.min(64.0, w / 4), bottom = math.min(80.0, w / 4);
    final points = [
      Offset(top, 0),
      Offset(w - top, 0),
      Offset(w - top, top),
      Offset(w, top),
      Offset(w, h - bottom),
      Offset(w - bottom, h - bottom),
      Offset(w - bottom, h),
      Offset(bottom, h),
      Offset(bottom, h - bottom),
      Offset(0, h - bottom),
      Offset(0, top),
      Offset(top, top),
    ];
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final corner = points[i];
      final before = points[(i + points.length - 1) % points.length] - corner;
      final after = points[(i + 1) % points.length] - corner;
      final radius = math.min(
        i >= 4 && i <= 9 ? 40.0 : 32.0,
        math.min(before.distance, after.distance) / 2,
      );
      final start = corner + before * (radius / before.distance);
      final end = corner + after * (radius / after.distance);
      if (i == 0) {
        path.moveTo(start.dx, start.dy);
      } else {
        path.lineTo(start.dx, start.dy);
      }
      path.quadraticBezierTo(corner.dx, corner.dy, end.dx, end.dy);
    }
    return path..close();
  }

  @override
  bool shouldReclip(_TouchpadClipper old) => false;
}

class _KeyboardDialog extends StatefulWidget {
  const _KeyboardDialog({required this.initial, required this.replace});
  final String initial;
  final bool replace;
  @override
  State<_KeyboardDialog> createState() => _KeyboardDialogState();
}

class _KeyboardDialogState extends State<_KeyboardDialog> {
  late final _text = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Fire TV keyboard'),
    content: TextField(
      controller: _text,
      autofocus: true,
      decoration: InputDecoration(
        labelText: widget.replace ? 'Text on your TV' : 'Text to enter',
      ),
      onSubmitted: (s) => Navigator.pop(context, s),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _text.text),
        child: const Text('Send'),
      ),
    ],
  );
}
