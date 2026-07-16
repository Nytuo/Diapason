import 'package:diapason/models/smart_playlist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

Future<SmartPlaylist?> showSmartPlaylistEditor(BuildContext context, {SmartPlaylist? existing}) {
  return showDialog<SmartPlaylist>(
    context: context,
    builder: (_) => _SmartPlaylistEditorDialog(existing: existing),
  );
}

class _SmartPlaylistEditorDialog extends StatefulWidget {
  const _SmartPlaylistEditorDialog({this.existing});
  final SmartPlaylist? existing;

  @override
  State<_SmartPlaylistEditorDialog> createState() => _SmartPlaylistEditorDialogState();
}

class _SmartPlaylistEditorDialogState extends State<_SmartPlaylistEditorDialog> {
  late final SmartPlaylist _draft;
  late final TextEditingController _nameController;
  late final TextEditingController _limitController;

  @override
  void initState() {
    super.initState();
    _draft =
        widget.existing?.copy() ??
        SmartPlaylist(
          id: "smart-${DateTime.now().microsecondsSinceEpoch}",
          name: "New Smart Playlist",
          rules: [SmartRule(field: SmartField.artist, op: SmartOp.contains, value: "")],
        );
    _nameController = TextEditingController(text: _draft.name);
    _limitController = TextEditingController(text: _draft.limit?.toString() ?? "");
  }

  @override
  void dispose() {
    _nameController.dispose();
    _limitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.existing == null ? "New Smart Playlist" : "Edit Smart Playlist"),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: "Name"),
                onChanged: (v) => _draft.name = v,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text("Match"),
                  const SizedBox(width: 12),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text("All")),
                      ButtonSegment(value: false, label: Text("Any")),
                    ],
                    selected: {_draft.matchAll},
                    onSelectionChanged: (s) => setState(() => _draft.matchAll = s.first),
                  ),
                  const Text("  of the rules"),
                ],
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < _draft.rules.length; i++) _ruleRow(i),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(
                    () => _draft.rules.add(SmartRule(field: SmartField.title, op: SmartOp.contains, value: "")),
                  ),
                  icon: const Icon(TablerIcons.plus, size: 18),
                  label: const Text("Add rule"),
                ),
              ),
              const Divider(),
              Row(
                children: [
                  const Text("Sort by"),
                  const SizedBox(width: 12),
                  DropdownButton<SmartSort>(
                    value: _draft.sort,
                    onChanged: (v) => setState(() => _draft.sort = v!),
                    items: SmartSort.values.map((s) => DropdownMenuItem(value: s, child: Text(s.label))).toList(),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: _draft.descending ? "Descending" : "Ascending",
                    onPressed: () => setState(() => _draft.descending = !_draft.descending),
                    icon: Icon(_draft.descending ? TablerIcons.sort_descending : TablerIcons.sort_ascending),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text("Limit"),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: _limitController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: "none"),
                      onChanged: (v) => _draft.limit = int.tryParse(v.trim()),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
        FilledButton(
          onPressed: () {
            _draft.name = _nameController.text.trim().isEmpty ? "Smart Playlist" : _nameController.text.trim();
            Navigator.of(context).pop(_draft);
          },
          child: const Text("Save"),
        ),
      ],
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
    );
  }

  Widget _ruleRow(int index) {
    final rule = _draft.rules[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButton<SmartField>(
              isExpanded: true,
              value: rule.field,
              onChanged: (v) => setState(() => rule.field = v!),
              items: SmartField.values.map((f) => DropdownMenuItem(value: f, child: Text(f.label))).toList(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: DropdownButton<SmartOp>(
              isExpanded: true,
              value: rule.op,
              onChanged: (v) => setState(() => rule.op = v!),
              items: SmartOp.values.map((o) => DropdownMenuItem(value: o, child: Text(o.label))).toList(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: rule.field.isBool
                ? DropdownButton<String>(
                    isExpanded: true,
                    value: (rule.value.toLowerCase() == "true" || rule.value.toLowerCase() == "yes") ? "true" : "false",
                    onChanged: (v) => setState(() => rule.value = v!),
                    items: const [
                      DropdownMenuItem(value: "true", child: Text("Yes")),
                      DropdownMenuItem(value: "false", child: Text("No")),
                    ],
                  )
                : TextField(
                    controller: TextEditingController(text: rule.value)
                      ..selection = TextSelection.collapsed(offset: rule.value.length),
                    keyboardType: rule.field.isNumeric ? TextInputType.number : TextInputType.text,
                    decoration: const InputDecoration(isDense: true, hintText: "value"),
                    onChanged: (v) => rule.value = v,
                  ),
          ),
          IconButton(
            icon: const Icon(TablerIcons.x, size: 18),
            onPressed: _draft.rules.length == 1 ? null : () => setState(() => _draft.rules.removeAt(index)),
          ),
        ],
      ),
    );
  }
}
