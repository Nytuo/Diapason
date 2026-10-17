import 'package:diapason/models/tv_profile.dart';
import 'package:diapason/screens/sources_settings_screen.dart';
import 'package:diapason/screens/tv/tv_widgets.dart';
import 'package:diapason/services/tv/tv_profile_service.dart';
import 'package:diapason/utils/tv_zoom.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Rename, recolour, add accounts to, or delete one profile. Takes the profile id as the route argument.
class TvProfileEditScreen extends StatefulWidget {
  const TvProfileEditScreen({super.key, required this.profileId});

  static const routeName = "/tv/profiles/edit";

  final String profileId;

  @override
  State<TvProfileEditScreen> createState() => _TvProfileEditScreenState();
}

class _TvProfileEditScreenState extends State<TvProfileEditScreen> {
  TvProfileService get _service => GetIt.instance<TvProfileService>();

  late final TextEditingController _name = TextEditingController(text: _profile?.name ?? "");

  TvProfile? get _profile => _service.profiles.where((p) => p.id == widget.profileId).firstOrNull;

  @override
  void initState() {
    super.initState();
    _service.addListener(_changed);
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    _name.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _addAccount() async {
    // New accounts go to the listening profile, so make this the listening profile first.
    await _service.select(widget.profileId);
    if (mounted) await Navigator.of(context).pushNamed(SourcesSettingsScreen.routeName);
    if (mounted) setState(() {});
  }

  Future<void> _delete() async {
    final profile = _profile;
    if (profile == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Delete ${profile.name}?"),
        content: const Text("Their accounts are forgotten on this TV. Nothing is deleted from the servers."),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text("Cancel")),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text("Delete")),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.delete(profile.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    if (profile == null) return const Scaffold(backgroundColor: Colors.black);
    final accounts = _service.sourcesOf(profile);

    return TvNative(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(48.0),
            children: [
              Row(
                children: [
                  TvAvatar(color: Color(profile.colorValue), initial: profile.initial, size: 96.0),
                  const SizedBox(width: 32.0),
                  Expanded(
                    child: TextField(
                      controller: _name,
                      style: const TextStyle(color: Colors.white, fontSize: 24.0),
                      textInputAction: TextInputAction.done,
                      onChanged: (value) => _service.rename(profile.id, value),
                      decoration: const InputDecoration(labelText: "Name", border: OutlineInputBorder()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32.0),
              Wrap(
                spacing: 16.0,
                runSpacing: 16.0,
                children: [
                  for (final color in TvProfile.defaultColors)
                    TvFocusable(
                      onPressed: () => _service.recolor(profile.id, color),
                      builder: (context, focused) => TvAvatar(
                        color: Color(color),
                        initial: "",
                        size: 56.0,
                        focused: focused || color == profile.colorValue,
                        icon: color == profile.colorValue ? TablerIcons.check : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 40.0),
              Text("Accounts", style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white)),
              const SizedBox(height: 12.0),
              if (accounts.isEmpty)
                const Text(
                  "No accounts yet. Add one to see music here.",
                  style: TextStyle(color: Colors.white54, fontSize: 18.0),
                ),
              for (final account in accounts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                  child: Text(
                    "${account.name}  ·  ${account.kind.name}",
                    style: const TextStyle(color: Colors.white70, fontSize: 20.0),
                  ),
                ),
              const SizedBox(height: 24.0),
              Wrap(
                spacing: 16.0,
                children: [
                  TvPillButton(
                    autofocus: true,
                    icon: TablerIcons.plus,
                    label: "Add an account",
                    onPressed: _addAccount,
                  ),
                  TvPillButton(icon: TablerIcons.trash, label: "Delete profile", onPressed: _delete),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
