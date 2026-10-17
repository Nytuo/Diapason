import 'package:diapason/models/tv_profile.dart';
import 'package:diapason/screens/sources_settings_screen.dart';
import 'package:diapason/screens/tv/tv_home_screen.dart';
import 'package:diapason/screens/tv/tv_profile_edit_screen.dart';
import 'package:diapason/screens/tv/tv_widgets.dart';
import 'package:diapason/services/tv/tv_profile_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// "Who's listening?": the first thing on a shared TV. Each profile keeps its own accounts.
class TvProfilePickerScreen extends StatefulWidget {
  const TvProfilePickerScreen({super.key});

  static const routeName = "/tv/profiles";

  @override
  State<TvProfilePickerScreen> createState() => _TvProfilePickerScreenState();
}

class _TvProfilePickerScreenState extends State<TvProfilePickerScreen> {
  TvProfileService get _service => GetIt.instance<TvProfileService>();

  bool _managing = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_changed);
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _choose(TvProfile profile) async {
    if (_managing) {
      await Navigator.of(context).pushNamed(TvProfileEditScreen.routeName, arguments: profile.id);
      return;
    }
    await _service.select(profile.id);
    if (mounted) await Navigator.of(context).pushNamedAndRemoveUntil(TvHomeScreen.routeName, (_) => false);
  }

  Future<void> _add() async {
    final name = await showDialog<String>(context: context, builder: (context) => const _NewProfileDialog());
    if (name == null || !mounted) return;
    final profile = await _service.create(name);
    await _service.select(profile.id);
    if (!mounted) return;
    // The new profile starts empty: take them straight to adding their first account.
    await Navigator.of(context).pushNamed(SourcesSettingsScreen.routeName);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final profiles = _service.profiles;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(48.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _managing ? "Manage profiles" : "Who's listening?",
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 48.0),
                Wrap(
                  spacing: 40.0,
                  runSpacing: 40.0,
                  alignment: WrapAlignment.center,
                  children: [
                    for (var i = 0; i < profiles.length; i++)
                      _ProfileTile(
                        key: ValueKey(profiles[i].id),
                        profile: profiles[i],
                        managing: _managing,
                        isActive: _service.active?.id == profiles[i].id,
                        autofocus: i == 0,
                        onPressed: () => _choose(profiles[i]),
                      ),
                    if (_service.canAddMore) _AddTile(autofocus: profiles.isEmpty, onPressed: _add),
                  ],
                ),
                const SizedBox(height: 56.0),
                if (profiles.isNotEmpty)
                  TvPillButton(
                    icon: _managing ? TablerIcons.check : TablerIcons.pencil,
                    label: _managing ? "Done" : "Manage profiles",
                    onPressed: () => setState(() => _managing = !_managing),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    super.key,
    required this.profile,
    required this.managing,
    required this.isActive,
    required this.onPressed,
    this.autofocus = false,
  });

  final TvProfile profile;
  final bool managing;
  final bool isActive;
  final bool autofocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      builder: (context, focused) => SizedBox(
        width: 160.0,
        child: Column(
          children: [
            Stack(
              alignment: Alignment.bottomRight,
              children: [
                TvAvatar(color: Color(profile.colorValue), initial: profile.initial, focused: focused),
                if (managing)
                  const CircleAvatar(
                    radius: 20.0,
                    backgroundColor: Colors.white,
                    child: Icon(TablerIcons.pencil, color: Colors.black),
                  ),
              ],
            ),
            const SizedBox(height: 16.0),
            Text(
              profile.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: focused ? Colors.white : Colors.white70, fontSize: 22.0),
            ),
            Text(
              "${profile.sourceIds.length} account${profile.sourceIds.length == 1 ? "" : "s"}",
              style: const TextStyle(color: Colors.white38, fontSize: 14.0),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onPressed, this.autofocus = false});

  final VoidCallback onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      builder: (context, focused) => SizedBox(
        width: 160.0,
        child: Column(
          children: [
            TvAvatar(color: Colors.white12, initial: "+", icon: TablerIcons.plus, focused: focused),
            const SizedBox(height: 16.0),
            Text("Add profile", style: TextStyle(color: focused ? Colors.white : Colors.white70, fontSize: 22.0)),
          ],
        ),
      ),
    );
  }
}

/// Asks for a name. Owns its text controller so it outlives the dialog's closing animation.
class _NewProfileDialog extends StatefulWidget {
  const _NewProfileDialog();

  @override
  State<_NewProfileDialog> createState() => _NewProfileDialogState();
}

class _NewProfileDialogState extends State<_NewProfileDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("New profile"),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.of(context).pop(value),
        decoration: const InputDecoration(labelText: "Name"),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
        FilledButton(onPressed: () => Navigator.of(context).pop(_controller.text), child: const Text("Create")),
      ],
    );
  }
}
