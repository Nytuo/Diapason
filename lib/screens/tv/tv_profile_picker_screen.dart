import 'package:diapason/models/tv_profile.dart';
import 'package:diapason/screens/sources_settings_screen.dart';
import 'package:diapason/screens/music_screen.dart';
import 'package:diapason/screens/tv/tv_profile_edit_screen.dart';
import 'package:diapason/screens/tv/tv_widgets.dart';
import 'package:diapason/services/tv/tv_profile_service.dart';
import 'package:diapason/utils/tv_zoom.dart';
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
    if (mounted) await Navigator.of(context).pushNamedAndRemoveUntil(MusicScreen.routeName, (_) => false);
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
    final theme = Theme.of(context);
    return TvNative(
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              // The same mark and name as the header of the home screen.
              Positioned(
                left: 56.0,
                top: 36.0,
                child: Row(
                  children: [
                    Image.asset(
                      "images/diapason_cropped.png",
                      width: 44,
                      height: 44,
                      errorBuilder: (_, _, _) => const SizedBox(width: 44, height: 44),
                    ),
                    const SizedBox(width: 14.0),
                    Text("Diapason", style: theme.textTheme.headlineSmall),
                  ],
                ),
              ),
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(48.0, 96.0, 48.0, 48.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_managing ? "Manage profiles" : "Who's listening?", style: theme.textTheme.displaySmall),
                      const SizedBox(height: 8.0),
                      Text(
                        _managing
                            ? "Choose a profile to rename it, change its colour or remove it."
                            : "Each profile has its own accounts and library.",
                        style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 48.0),
                      Wrap(
                        spacing: 28.0,
                        runSpacing: 28.0,
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
                      const SizedBox(height: 48.0),
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
            ],
          ),
        ),
      ),
    );
  }
}

/// A card in the style of the home screen's buttons: a tinted rounded rectangle, with a Material outline when focused.
class _TvCard extends StatelessWidget {
  const _TvCard({required this.focused, required this.child});

  final bool focused;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 200.0,
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 24.0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20.0),
        color: scheme.primary.withValues(alpha: focused ? 0.22 : 0.10),
        border: Border.all(color: focused ? scheme.onSurface : Colors.transparent, width: 3.0),
      ),
      child: child,
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
    final theme = Theme.of(context);
    final accounts = "${profile.sourceIds.length} account${profile.sourceIds.length == 1 ? "" : "s"}";
    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      builder: (context, focused) => _TvCard(
        focused: focused,
        child: Column(
          children: [
            Stack(
              alignment: Alignment.bottomRight,
              children: [
                TvAvatar(color: Color(profile.colorValue), initial: profile.initial, size: 104.0),
                if (managing)
                  CircleAvatar(
                    radius: 18.0,
                    backgroundColor: theme.colorScheme.surface,
                    child: Icon(TablerIcons.pencil, size: 18.0, color: theme.colorScheme.onSurface),
                  ),
              ],
            ),
            const SizedBox(height: 16.0),
            Text(profile.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge),
            const SizedBox(height: 2.0),
            Text(accounts, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
    final theme = Theme.of(context);
    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      builder: (context, focused) => _TvCard(
        focused: focused,
        child: Column(
          children: [
            TvAvatar(
              color: theme.colorScheme.primary.withValues(alpha: 0.25),
              initial: "+",
              icon: TablerIcons.plus,
              size: 104.0,
            ),
            const SizedBox(height: 16.0),
            Text("Add profile", style: theme.textTheme.titleLarge),
            const SizedBox(height: 2.0),
            // Keeps the card as tall as the profile cards.
            Text("", style: theme.textTheme.bodyMedium),
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
