import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../services/finamp_logs_helper.dart';
import 'log_tile.dart';

class LogsView extends StatelessWidget {
  const LogsView({super.key});

  @override
  Widget build(BuildContext context) {
    FinampLogsHelper finampLogsHelper = GetIt.instance<FinampLogsHelper>();

    final logs = finampLogsHelper.logs;
    return ListView.builder(
      itemCount: logs.length,
      reverse: true,
      itemBuilder: (context, index) {
        // Newest first; index straight into the list instead of building a reversed view twice per item.
        final record = logs[logs.length - 1 - index];
        return LogTile(key: ValueKey(record.sequenceNumber), logRecord: record);
      },
    );
  }
}
