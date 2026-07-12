package fr.nytuo.diapason

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * The home-screen widget: what's playing, and a tap target to open the app.
 */
class DiapasonWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val data = HomeWidgetPlugin.getData(context)

        for (widgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.diapason_widget).apply {
                val title = data.getString("title", "") ?: ""
                val artist = data.getString("artist", "") ?: ""

                setTextViewText(
                    R.id.widget_title,
                    if (title.isEmpty()) context.getString(R.string.app_name) else title,
                )
                setTextViewText(R.id.widget_artist, artist)

                val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                val pending = PendingIntent.getActivity(
                    context,
                    0,
                    launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                setOnClickPendingIntent(R.id.widget_root, pending)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
