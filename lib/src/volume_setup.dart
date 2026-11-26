import 'package:flutter/material.dart';
import 'receiver.dart';

// Setting names from Amazon's "Manage the HDMI ARC or HDMI CEC Setting on Your TV".
const _cecSettings = {
  'Samsung': 'Enable Anynet+ in External Device Manager or Expert Settings.',
  'LG': 'Enable SIMPLINK in the General settings.',
  'Sony': 'Enable BRAVIA Sync control under External inputs.',
  'Roku TV':
      'Under System, open Control other devices (CEC) and enable System audio control.',
  'Panasonic': 'Look for VIERA Link, HDAVI Control or EZ Sync and turn it on.',
  'Philips':
      'Open EasyLink settings and enable EasyLink and remote control forwarding.',
  'Sharp': 'Open AQUOS Link Setup and enable AQUOS Link Control.',
  'Toshiba': 'Enable CE-Link or REGZA-LINK in the HDMI settings.',
  'Vizio': 'Enable CEC in the System settings.',
  'Hitachi': 'Enable HDMI-CEC in the Setup menu.',
  'Other TV':
      'Look for HDMI-CEC in the HDMI, inputs or system settings. The name varies by model.',
};

class VolumeSetupHelp extends StatefulWidget {
  const VolumeSetupHelp({
    super.key,
    required this.controls,
    required this.showHelp,
  });
  final List<AudioControl> controls;
  final bool showHelp;
  @override
  State<VolumeSetupHelp> createState() => _VolumeSetupHelpState();
}

class _VolumeSetupHelpState extends State<VolumeSetupHelp> {
  String? _brand;

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('TV volume setup'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.showHelp)
          const Text(
            'Play something on your TV, then choose a control to test.',
          )
        else ...[
          const Text(
            'Enable HDMI-CEC in your TV settings, then try the control again.',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            decoration: const InputDecoration(labelText: 'TV brand'),
            isExpanded: true,
            items: [
              for (final brand in _cecSettings.keys)
                DropdownMenuItem(value: brand, child: Text(brand)),
            ],
            onChanged: (brand) => setState(() => _brand = brand),
          ),
          if (_brand != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_cecSettings[_brand]!),
            ),
          const SizedBox(height: 16),
          const Text(
            'Using a soundbar? Check Equipment Control in the Fire TV settings.',
          ),
        ],
        const SizedBox(height: 12),
        for (final control in widget.controls)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              control == AudioControl.mute
                  ? Icons.volume_off_outlined
                  : Icons.volume_up_outlined,
            ),
            title: Text(control.testLabel),
            onTap: () => Navigator.pop(context, control),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
