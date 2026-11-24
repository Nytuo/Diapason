import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/scrobbling/lastfm_client.dart';
import 'package:diapason/services/scrobbling/listenbrainz_client.dart';
import 'package:diapason/services/scrobbling/scrobble_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:url_launcher/url_launcher.dart';

class ScrobblingSettingsScreen extends ConsumerStatefulWidget {
  const ScrobblingSettingsScreen({super.key});

  static const routeName = "/settings/scrobbling";

  @override
  ConsumerState<ScrobblingSettingsScreen> createState() => _ScrobblingSettingsScreenState();
}

class _ScrobblingSettingsScreenState extends ConsumerState<ScrobblingSettingsScreen> {
  late final _token = TextEditingController(text: FinampSettingsHelper.finampSettings.listenBrainzToken);
  late final _apiKey = TextEditingController(text: FinampSettingsHelper.finampSettings.lastFmApiKey);
  late final _apiSecret = TextEditingController(text: FinampSettingsHelper.finampSettings.lastFmApiSecret);

  bool _validating = false;
  String? _pendingLastFmToken;

  @override
  void dispose() {
    _token.dispose();
    _apiKey.dispose();
    _apiSecret.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveListenBrainz() async {
    final l10n = AppLocalizations.of(context)!;
    final token = _token.text.trim();
    if (token.isEmpty) {
      FinampSetters.setListenBrainzToken("");
      _snack(l10n.scrobbleLbDisconnected);
      return;
    }

    setState(() => _validating = true);
    final valid = await ListenBrainzClient().validateToken(token);
    setState(() => _validating = false);

    if (valid) {
      FinampSetters.setListenBrainzToken(token);
      _snack(l10n.scrobbleLbConnected);
    } else {
      _snack(l10n.scrobbleLbRejected);
    }
  }

  LastFmClient get _lastFm => LastFmClient(apiKey: _apiKey.text.trim(), apiSecret: _apiSecret.text.trim());

  Future<void> _startLastFmAuth() async {
    final l10n = AppLocalizations.of(context)!;
    final client = _lastFm;
    if (!client.isConfigured) {
      _snack(l10n.scrobbleLfmEnterKey);
      return;
    }

    final token = await client.requestToken();
    if (token == null) {
      _snack(l10n.scrobbleLfmKeyRejected);
      return;
    }

    setState(() => _pendingLastFmToken = token);
    await launchUrl(client.authorizationUrl(token), mode: LaunchMode.externalApplication);
  }

  Future<void> _finishLastFmAuth() async {
    final l10n = AppLocalizations.of(context)!;
    final token = _pendingLastFmToken;
    if (token == null) return;

    final session = await _lastFm.session(token);
    if (session == null) {
      _snack(l10n.scrobbleLfmNotAuthorised);
      return;
    }

    FinampSetters.setLastFmApiKey(_apiKey.text.trim());
    FinampSetters.setLastFmApiSecret(_apiSecret.text.trim());
    FinampSetters.setLastFmSessionKey(session.sessionKey);
    FinampSetters.setLastFmUsername(session.username);
    setState(() => _pendingLastFmToken = null);
    _snack(l10n.scrobbleLfmConnectedAs(session.username));
  }

  void _disconnectLastFm() {
    FinampSetters.setLastFmSessionKey("");
    FinampSetters.setLastFmUsername("");
    _snack(AppLocalizations.of(context)!.scrobbleLfmDisconnected);
  }

  @override
  Widget build(BuildContext context) {
    final lastFmUser = ref.watch(finampSettingsProvider.lastFmUsername);
    final listenBrainzConnected = ref.watch(finampSettingsProvider.listenBrainzToken).isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context)!.scrobbleTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Text("ListenBrainz", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8.0),
          TextField(
            controller: _token,
            obscureText: true,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context)!.scrobbleUserToken,
              helperText: AppLocalizations.of(context)!.scrobbleUserTokenHelper,
              suffixIcon: listenBrainzConnected ? const Icon(TablerIcons.circle_check) : null,
            ),
          ),
          const SizedBox(height: 12.0),
          FilledButton(
            onPressed: _validating ? null : _saveListenBrainz,
            child: _validating
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(
                    listenBrainzConnected
                        ? AppLocalizations.of(context)!.scrobbleUpdate
                        : AppLocalizations.of(context)!.scrobbleConnect,
                  ),
          ),

          const Divider(height: 48.0),

          Text("Last.fm", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8.0),
          if (lastFmUser.isNotEmpty)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(TablerIcons.circle_check),
              title: Text(AppLocalizations.of(context)!.scrobbleConnectedAs(lastFmUser)),
              trailing: TextButton(
                onPressed: _disconnectLastFm,
                child: Text(AppLocalizations.of(context)!.scrobbleDisconnect),
              ),
            )
          else ...[
            Text(AppLocalizations.of(context)!.scrobbleLfmKeyInfo),
            const SizedBox(height: 12.0),
            TextField(
              controller: _apiKey,
              autocorrect: false,
              decoration: InputDecoration(labelText: AppLocalizations.of(context)!.scrobbleApiKey),
            ),
            const SizedBox(height: 12.0),
            TextField(
              controller: _apiSecret,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(labelText: AppLocalizations.of(context)!.scrobbleSharedSecret),
            ),
            const SizedBox(height: 12.0),
            if (_pendingLastFmToken == null)
              FilledButton(onPressed: _startLastFmAuth, child: Text(AppLocalizations.of(context)!.scrobbleAuthorise))
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(AppLocalizations.of(context)!.scrobbleApproveHint),
                  const SizedBox(height: 8.0),
                  FilledButton(
                    onPressed: _finishLastFmAuth,
                    child: Text(AppLocalizations.of(context)!.scrobbleApproved),
                  ),
                ],
              ),
          ],

          const Divider(height: 48.0),

          FutureBuilder<int>(
            future: GetIt.instance<ScrobbleService>().pendingCount(),
            builder: (context, snapshot) {
              final pending = snapshot.data ?? 0;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(AppLocalizations.of(context)!.scrobbleWaiting),
                subtitle: Text(
                  pending == 0
                      ? AppLocalizations.of(context)!.scrobbleNothingQueued
                      : AppLocalizations.of(context)!.scrobbleQueued(pending),
                ),
                trailing: pending == 0
                    ? null
                    : TextButton(
                        onPressed: () async {
                          await GetIt.instance<ScrobbleService>().retryPending();
                          setState(() {});
                        },
                        child: Text(AppLocalizations.of(context)!.scrobbleRetry),
                      ),
              );
            },
          ),
        ],
      ),
    );
  }
}
