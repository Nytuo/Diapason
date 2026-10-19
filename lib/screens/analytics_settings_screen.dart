import 'package:diapason/components/finamp_app_bar_back_button.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _usageTitle = "Share anonymous usage counts";
const _usageSubtitle =
    "Lets the developer see how many people use Diapason (e.g. app launches). No library, track or account data.";
const _bugTitle = "Send anonymous bug reports";
const _bugSubtitle =
    "When the app hits an unexpected error, send its type, a short message and the stack trace. URLs are removed.";

class AnalyticsSettingsScreen extends ConsumerWidget {
  const AnalyticsSettingsScreen({super.key});
  static const routeName = "/settings/analytics";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text("Analytics & bug reports"), leading: FinampAppBarBackButton()),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              "Both options are off by default and independent of each other. Data goes to a self-hosted Aptabase "
              "instance (analytics.nytuo.fr), is not linked to your account and is never sold or shared.",
            ),
          ),
          SwitchListTile.adaptive(
            title: const Text(_usageTitle),
            subtitle: const Text(_usageSubtitle),
            value: ref.watch(finampSettingsProvider.analyticsEnabled),
            onChanged: FinampSetters.setAnalyticsEnabled,
          ),
          SwitchListTile.adaptive(
            title: const Text(_bugTitle),
            subtitle: const Text(_bugSubtitle),
            value: ref.watch(finampSettingsProvider.bugReportsEnabled),
            onChanged: FinampSetters.setBugReportsEnabled,
          ),
        ],
      ),
    );
  }
}

/// One-time dialog asking for the two opt-ins. Dismissing it keeps both off.
class AnalyticsConsentDialog extends StatefulWidget {
  const AnalyticsConsentDialog({super.key});

  static bool _showing = false;

  static Future<void> showIfNeeded(BuildContext context) async {
    if (_showing || FinampSettingsHelper.finampSettings.analyticsPromptShown) return;
    _showing = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AnalyticsConsentDialog(),
      );
    } finally {
      _showing = false;
    }
  }

  @override
  State<AnalyticsConsentDialog> createState() => _AnalyticsConsentDialogState();
}

class _AnalyticsConsentDialogState extends State<AnalyticsConsentDialog> {
  bool _usage = false;
  bool _bugs = false;

  void _finish() {
    FinampSetters.setAnalyticsEnabled(_usage);
    FinampSetters.setBugReportsEnabled(_bugs);
    FinampSetters.setAnalyticsPromptShown(true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Help improve Diapason?"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Both are optional, anonymous and off unless you turn them on. You can change this any time in "
              "Settings → Analytics & bug reports.",
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text(_usageTitle),
              subtitle: const Text(_usageSubtitle),
              value: _usage,
              onChanged: (v) => setState(() => _usage = v),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text(_bugTitle),
              subtitle: const Text(_bugSubtitle),
              value: _bugs,
              onChanged: (v) => setState(() => _bugs = v),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: _finish, child: Text(_usage || _bugs ? "Save" : "No thanks"))],
    );
  }
}
