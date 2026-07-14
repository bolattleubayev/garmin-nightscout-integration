using Toybox.Application as Application;
using Toybox.WatchUi as WatchUi;
using Toybox.Graphics as Graphics;
using Toybox.System as System;
using Toybox.Communications as Communications;
using Toybox.Background as Background;
using Toybox.Time as Time;
using Toybox.Time.Gregorian as Gregorian;
using Toybox.Lang as Lang;
using Toybox.Math as Math;
using Toybox.Activity as Activity;
using Toybox.ActivityMonitor as ActivityMonitor;
using Toybox.PersistedContent;
using Toybox.Cryptography as Cryptography;

class SimpleWatchFaceApp extends Application.AppBase {
    function initialize() { AppBase.initialize(); }
    function getInitialView() { return [new SimpleWatchFaceView()]; }
    function getServiceDelegate() { return [new NightscoutDelegate()]; }
    function onStart(state as Lang.Dictionary?) as Void {
        Background.registerForTemporalEvent(new Time.Duration(5 * 60));
    }
}

(:background)
class NightscoutDelegate extends System.ServiceDelegate {
    (:background)
    function initialize() { ServiceDelegate.initialize(); }

    (:background)
    function onTemporalEvent() as Void {
        var url = Application.Properties.getValue("NightscoutUrl") as Lang.String?;
        var secret = Application.Properties.getValue("NightscoutSecret") as Lang.String?;
        if (url == null || url.length() == 0 || secret == null || secret.length() == 0) {
            Background.exit(null);
            return;
        }
        if (url.substring(url.length() - 1, url.length()).equals("/")) {
            url = url.substring(0, url.length() - 1);
        }

        var oneHourAgoMs = (Time.now().value() - 3600).toLong() * 1000;
        Communications.makeWebRequest(
            url + "/api/v1/entries/sgv.json",
            {
                "find[date][$gte]" => oneHourAgoMs,
                "count" => 13,
                "token" => sha1Hex(secret)
            },
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onResponse)
        );
    }

    (:background)
    hidden function sha1Hex(secret as Lang.String) as Lang.String {
        var bytes = ([]b).addAll(secret.toUtf8Array());
        var hash = new Cryptography.Hash({ :algorithm => Cryptography.HASH_SHA1 });
        hash.update(bytes);
        var digest = hash.digest();
        var hexChars = "0123456789abcdef";
        var result = "";
        for (var i = 0; i < digest.size(); i++) {
            var b = digest[i];
            if (b < 0) { b += 256; }
            result += hexChars.substring((b >> 4) & 0xF, ((b >> 4) & 0xF) + 1);
            result += hexChars.substring(b & 0xF, (b & 0xF) + 1);
        }
        return result;
    }

    (:background)
    function onResponse(responseCode as Lang.Number, data as Lang.Dictionary or Lang.String or PersistedContent.Iterator or Null) as Void {
        if (responseCode == 200 && data != null) {
            var obj = data as Lang.Object;
            if (obj instanceof Lang.Array) {
                var arr = obj as Lang.Array;
                if (arr.size() > 0) {
                    var latest = arr[0] as Lang.Dictionary;
                    Application.Storage.setValue("cgmMmol", (latest["sgv"] as Lang.Number).toFloat() / 18.0);
                    Application.Storage.setValue("cgmDate", (latest["date"] as Lang.Number).toLong());

                    // API returns newest-first; reverse so index 0 = oldest
                    var size = arr.size();
                    var history = new [size];
                    var timestamps = new [size]; // seconds since epoch, stored as Number (safe until 2038)
                    for (var i = 0; i < size; i++) {
                        var entry = arr[size - 1 - i] as Lang.Dictionary;
                        history[i] = (entry["sgv"] as Lang.Number).toFloat() / 18.0;
                        timestamps[i] = ((entry["date"] as Lang.Number).toLong() / 1000l).toNumber();
                    }
                    Application.Storage.setValue("cgmHistory", history);
                    Application.Storage.setValue("cgmTimestamps", timestamps);
                }
            }
        }
        Background.exit(null);
    }
}

class SimpleWatchFaceView extends WatchUi.WatchFace {
    // Muted palette — avoids raw 8-bit primaries so the face reads closer to native Garmin faces
    const COLOR_TEXT_PRIMARY = 0xE8E8E8;   // time
    const COLOR_TEXT_SECONDARY = 0x999999; // HR/steps values, CGM placeholder
    const COLOR_TEXT_TERTIARY = 0x666666;  // unit labels, date, battery %, "min ago", plot labels
    const COLOR_GRID_LINE = 0x333333;      // plot grid/tick lines

    const COLOR_GOOD = 0x3DDC84;     // muted green — in range / battery ok
    const COLOR_HIGH = 0xFFB300;     // muted amber — high / battery mid
    const COLOR_LOW = 0xE84C3D;      // muted red — low / battery critical
    const COLOR_GOOD_DIM = 0x1A4D2E;
    const COLOR_HIGH_DIM = 0x664400;
    const COLOR_LOW_DIM = 0x662018;

    function initialize() { WatchFace.initialize(); }

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;
        var r = cx - 3;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // Battery (top center)
        var battery = System.getSystemStats().battery.toNumber();
        var batBodyW = 36; var batBodyH = 18; var batTipW = 5; var batTipH = 11;
        var batText = battery + "%";
        var batTextW = dc.getTextWidthInPixels(batText, Graphics.FONT_XTINY);
        var batGap = 7;
        var batGroupX = cx - (batBodyW + batTipW + batGap + batTextW) / 2;
        var batX = batGroupX;
        var batY = 38 - batBodyH / 2;
        var batR = 3;
        var batFillColor = battery <= 20 ? COLOR_LOW : (battery <= 50 ? COLOR_HIGH : COLOR_GOOD);
        dc.setColor(batFillColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawRoundedRectangle(batX, batY, batBodyW, batBodyH, batR);
        dc.fillRoundedRectangle(batX + batBodyW, batY + (batBodyH - batTipH) / 2, batTipW, batTipH, 2);
        dc.setPenWidth(1);
        var batFillW = ((batBodyW - 6) * battery / 100).toNumber();
        if (batFillW > 0) {
            dc.fillRoundedRectangle(batX + 3, batY + 3, batFillW, batBodyH - 6, batR - 1);
        }
        dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(batGroupX + batBodyW + batTipW + batGap, 38, Graphics.FONT_XTINY, batText,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Date
        var info = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
        var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 66, Graphics.FONT_XTINY,
            days[info.day_of_week - 1] + " " + info.day + " " + months[info.month - 1],
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Time (center)
        var clockTime = System.getClockTime();
        var timeText = clockTime.hour.format("%02d") + ":" + clockTime.min.format("%02d");
        var yTime = 133;
        dc.setColor(COLOR_TEXT_PRIMARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yTime, Graphics.FONT_NUMBER_MILD, timeText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Heart rate (left of time)
        var actInfo = Activity.getActivityInfo();
        var hr = actInfo != null ? actInfo.currentHeartRate : null;
        var xHr = 87;
        dc.setColor(COLOR_TEXT_SECONDARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(xHr, yTime - 8, Graphics.FONT_XTINY,
            hr != null ? hr.toString() : "--",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(xHr, yTime + 14, Graphics.FONT_XTINY, "bpm",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Steps (right of time)
        var xSteps = w - 87;
        var actMonInfo = ActivityMonitor.getInfo();
        var steps = actMonInfo != null ? actMonInfo.steps : null;
        dc.setColor(COLOR_TEXT_SECONDARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(xSteps, yTime - 8, Graphics.FONT_XTINY,
            steps != null ? formatThousands(steps) : "--",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(xSteps, yTime + 14, Graphics.FONT_XTINY, "steps",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // CGM data
        var history = Application.Storage.getValue("cgmHistory") as Lang.Array?;
        var timestamps = Application.Storage.getValue("cgmTimestamps") as Lang.Array?;
        var dateMs = Application.Storage.getValue("cgmDate") as Lang.Long?;

        if (history != null && history.size() > 0 && dateMs != null) {
            drawScatterPlot(dc, history, timestamps, w, h, dateMs);
        }

        // CGM value + trend (bottom)
        var yCgm = 373;
        var mmol = Application.Storage.getValue("cgmMmol") as Lang.Float?;
        if (mmol != null && dateMs != null) {
            var minsAgo = ((Time.now().value() - dateMs.toLong() / 1000l) / 60).toNumber();

            var trend = null;
            var delta = null;
            if (history != null && timestamps != null && history.size() > 0) {
                var slope = computeTrendSlope(history, timestamps);
                if (slope != null) { trend = slopeToTrend(slope); }
                delta = computeDelta15(history, timestamps, mmol);
            }

            var valueText = mmol.format("%.1f");
            var cgmColor = glucoseColor(mmol);
            dc.setColor(cgmColor, Graphics.COLOR_TRANSPARENT);
            if (trend != null) {
                var valueW = dc.getTextWidthInPixels(valueText, Graphics.FONT_NUMBER_MILD);
                var arrowW = 34;
                var gap = 10;
                var groupLeft = cx - (valueW + gap + arrowW) / 2;
                var arrowCx = groupLeft + valueW + gap + arrowW / 2;
                dc.drawText(groupLeft, yCgm, Graphics.FONT_NUMBER_MILD, valueText,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
                // Arrow+delta are stacked as one unit and re-centered as a pair on yCgm,
                // so together they align with the glucose value's vertical center instead
                // of the arrow alone sitting on yCgm and the delta trailing further down.
                drawTrendArrow(dc, trend as Lang.Number, arrowCx, yCgm - 10, cgmColor, 0.85f);
                if (delta != null) {
                    var deltaText = ((delta as Lang.Float) >= 0.0f ? "+" : "") + (delta as Lang.Float).format("%.1f");
                    dc.setColor(COLOR_TEXT_SECONDARY, Graphics.COLOR_TRANSPARENT);
                    dc.drawText(arrowCx, yCgm + 17, Graphics.FONT_XTINY, deltaText,
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
                }
            } else {
                dc.drawText(cx, yCgm, Graphics.FONT_NUMBER_MILD, valueText,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }

            dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, yCgm + 46, Graphics.FONT_XTINY, minsAgo + " min ago",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            dc.setColor(COLOR_TEXT_SECONDARY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, yCgm, Graphics.FONT_NUMBER_MILD, "--",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // OLS slope in mmol/L per minute. Single-pass O(n), O(1) space.
    // Returns null if newest reading > 20 min old or fewer than 3 points in window.
    hidden function computeTrendSlope(history as Lang.Array, timestamps as Lang.Array) as Lang.Float? {
        var count = history.size();
        if (count < 2 || timestamps.size() < count) { return null; }

        var nowSecs = Time.now().value().toNumber();
        var latestSecs = timestamps[count - 1] as Lang.Number;
        if (nowSecs - latestSecs > 1200) { return null; }

        var windowSecs = 1800; // 30-minute rolling window
        var n = 0;
        var sumX = 0.0f;
        var sumY = 0.0f;
        var sumXY = 0.0f;
        var sumX2 = 0.0f;
        var prevTs = -1;

        for (var i = 0; i < count; i++) {
            var ts = timestamps[i] as Lang.Number;
            var secsAgo = nowSecs - ts;
            if (secsAgo > windowSecs || secsAgo < 0) { continue; }
            if (ts == prevTs) { continue; } // skip duplicate timestamps
            prevTs = ts;

            var x = secsAgo.toFloat() / -60.0f; // minutes from now, negative = past
            var y = (history[i] as Lang.Float).toFloat();
            n++;
            sumX += x;
            sumY += y;
            sumXY += x * y;
            sumX2 += x * x;
        }

        if (n < 3) { return null; }
        var denom = n.toFloat() * sumX2 - sumX * sumX;
        if (denom > -0.01f && denom < 0.01f) { return 0.0f; }
        return (n.toFloat() * sumXY - sumX * sumY) / denom;
    }

    // mmol/L change vs the reading closest to 15 minutes ago. Returns null if no
    // reading falls within 5 minutes of that mark (sparse/gappy history).
    hidden function computeDelta15(history as Lang.Array, timestamps as Lang.Array, latestVal as Lang.Float) as Lang.Float? {
        var count = timestamps.size();
        if (count < 2 || history.size() < count) { return null; }

        var nowSecs = Time.now().value().toNumber();
        var target = nowSecs - 900;
        var bestIdx = -1;
        var bestDiff = 999999;
        for (var i = 0; i < count; i++) {
            var ts = timestamps[i] as Lang.Number;
            var diff = (ts - target).abs();
            if (diff < bestDiff) {
                bestDiff = diff;
                bestIdx = i;
            }
        }
        if (bestIdx < 0 || bestDiff > 300) { return null; }
        return latestVal - (history[bestIdx] as Lang.Float).toFloat();
    }

    // Thresholds from Dexcom standard: 1 mg/dL/min = 0.0556 mmol/L/min
    hidden function slopeToTrend(slope as Lang.Float) as Lang.Number {
        if (slope < -0.17f)  { return -3; } // ↓↓ > 3 mmol/hr fall
        if (slope < -0.11f)  { return -2; } // ↓  2–3 mmol/hr fall
        if (slope < -0.056f) { return -1; } // ↘  1–2 mmol/hr fall
        if (slope <= 0.056f) { return  0; } // →  < 1 mmol/hr change
        if (slope <= 0.11f)  { return  1; } // ↗  1–2 mmol/hr rise
        if (slope <= 0.17f)  { return  2; } // ↑  2–3 mmol/hr rise
        return 3;                            // ↑↑ > 3 mmol/hr rise
    }

    // trend: -3=↓↓  -2=↓  -1=↘  0=→  1=↗  2=↑  3=↑↑
    // Drawn centered at (cx, cy); scale shrinks/grows the whole glyph proportionally
    // (e.g. 0.7 to leave room for a delta label stacked underneath).
    hidden function drawTrendArrow(dc as Graphics.Dc, trend as Lang.Number, cx as Lang.Number, cy as Lang.Number, color as Graphics.ColorType, scale as Lang.Float) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        if (trend == 0) {
            // → flat
            dc.drawLine(cx - (18 * scale).toNumber(), cy, cx + (6 * scale).toNumber(), cy);
            dc.fillPolygon([[cx + (6 * scale).toNumber(), cy - (9 * scale).toNumber()], [cx + (6 * scale).toNumber(), cy + (9 * scale).toNumber()], [cx + (21 * scale).toNumber(), cy]]);
        } else if (trend == 2) {
            // ↑ up: stem + triangle head
            dc.drawLine(cx, cy + (15 * scale).toNumber(), cx, cy - (6 * scale).toNumber());
            dc.fillPolygon([[cx - (9 * scale).toNumber(), cy - (6 * scale).toNumber()], [cx + (9 * scale).toNumber(), cy - (6 * scale).toNumber()], [cx, cy - (21 * scale).toNumber()]]);
        } else if (trend == -2) {
            // ↓ down: stem + triangle head
            dc.drawLine(cx, cy - (15 * scale).toNumber(), cx, cy + (6 * scale).toNumber());
            dc.fillPolygon([[cx - (9 * scale).toNumber(), cy + (6 * scale).toNumber()], [cx + (9 * scale).toNumber(), cy + (6 * scale).toNumber()], [cx, cy + (21 * scale).toNumber()]]);
        } else if (trend == 1) {
            // ↗ diagonal up-right: stem + right-angle head at tip
            dc.drawLine(cx - (15 * scale).toNumber(), cy + (15 * scale).toNumber(), cx + (6 * scale).toNumber(), cy - (6 * scale).toNumber());
            dc.fillPolygon([[cx + (6 * scale).toNumber(), cy - (6 * scale).toNumber()], [cx - (6 * scale).toNumber(), cy - (6 * scale).toNumber()], [cx + (6 * scale).toNumber(), cy + (6 * scale).toNumber()]]);
        } else if (trend == -1) {
            // ↘ diagonal down-right: stem + right-angle head at tip
            dc.drawLine(cx - (15 * scale).toNumber(), cy - (15 * scale).toNumber(), cx + (6 * scale).toNumber(), cy + (6 * scale).toNumber());
            dc.fillPolygon([[cx + (6 * scale).toNumber(), cy + (6 * scale).toNumber()], [cx - (6 * scale).toNumber(), cy + (6 * scale).toNumber()], [cx + (6 * scale).toNumber(), cy - (6 * scale).toNumber()]]);
        } else if (trend == 3) {
            // ↑↑ two upward chevrons (∧∧)
            dc.drawLine(cx - (12 * scale).toNumber(), cy + (3 * scale).toNumber(), cx, cy - (9 * scale).toNumber());
            dc.drawLine(cx, cy - (9 * scale).toNumber(), cx + (12 * scale).toNumber(), cy + (3 * scale).toNumber());
            dc.drawLine(cx - (12 * scale).toNumber(), cy + (15 * scale).toNumber(), cx, cy + (3 * scale).toNumber());
            dc.drawLine(cx, cy + (3 * scale).toNumber(), cx + (12 * scale).toNumber(), cy + (15 * scale).toNumber());
        } else {
            // ↓↓ two downward chevrons (∨∨)
            dc.drawLine(cx - (12 * scale).toNumber(), cy - (3 * scale).toNumber(), cx, cy + (9 * scale).toNumber());
            dc.drawLine(cx, cy + (9 * scale).toNumber(), cx + (12 * scale).toNumber(), cy - (3 * scale).toNumber());
            dc.drawLine(cx - (12 * scale).toNumber(), cy - (15 * scale).toNumber(), cx, cy - (3 * scale).toNumber());
            dc.drawLine(cx, cy - (3 * scale).toNumber(), cx + (12 * scale).toNumber(), cy - (15 * scale).toNumber());
        }
        dc.setPenWidth(1);
    }

    hidden function drawScatterPlot(dc as Graphics.Dc, history as Lang.Array, timestamps as Lang.Array?, w as Lang.Number, h as Lang.Number, latestDateMs as Lang.Long) as Void {
        var cx = w / 2;
        var cy = h / 2;
        var r = cx - 3;
        var plotBottom = 308;
        var plotTop = 178;
        // plotBottom is farther from screen center than plotTop, so it's the tightest row —
        // basing the margin on it keeps both plot edges as close to the circle as safely possible
        var margin = circleInnerLeftX(cx, cy, r, plotBottom, 6);
        var plotHeight = plotBottom - plotTop;
        var plotWidth = w - 2 * margin;
        var count = history.size();
        var windowSecs = 3600l;
        var nowSecs = Time.now().value();
        var latestSecs = latestDateMs / 1000l;

        var mmolMin = (history[0] as Lang.Float).toFloat();
        var mmolMax = mmolMin;
        for (var i = 1; i < count; i++) {
            var v = (history[i] as Lang.Float).toFloat();
            if (v < mmolMin) { mmolMin = v; }
            if (v > mmolMax) { mmolMax = v; }
        }

        var edgePad = 0.25f;
        var loVal = mmolMin - edgePad;
        var hiVal = mmolMax + edgePad;
        var valRange = hiVal - loVal;
        if (valRange < 0.1f) { valRange = 0.1f; }

        var yMax = plotBottom - ((mmolMax - loVal) / valRange * plotHeight).toNumber();
        var yMin = plotBottom - ((mmolMin - loVal) / valRange * plotHeight).toNumber();

        // Start lines after the left-side labels so they don't overlap
        var maxX = circleInnerLeftX(cx, cy, r, plotTop + 7, 5);
        var minX = circleInnerLeftX(cx, cy, r, plotBottom - 7, 5);
        var maxLabelW = dc.getTextWidthInPixels(mmolMax.format("%.1f"), Graphics.FONT_XTINY);
        var minLabelW = dc.getTextWidthInPixels(mmolMin.format("%.1f"), Graphics.FONT_XTINY);
        dc.setColor(COLOR_GRID_LINE, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(maxX + maxLabelW + 5, yMax, margin + plotWidth, yMax);
        dc.drawLine(minX + minLabelW + 5, yMin, margin + plotWidth, yMin);

        var tickMins = [45, 30, 15];
        var tickLabels = ["-45m", "-30m", "-15m"];
        for (var t = 0; t < 3; t++) {
            var xTick = margin + ((1.0f - tickMins[t] * 60.0f / windowSecs.toFloat()) * plotWidth).toNumber();
            dc.setColor(COLOR_GRID_LINE, Graphics.COLOR_TRANSPARENT);
            dc.drawLine(xTick, plotTop, xTick, plotBottom);
            dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(xTick, plotBottom + 14, Graphics.FONT_XTINY, tickLabels[t],
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        var lastDotX = -1;
        var lastDotY = -1;
        var lastDotColor = COLOR_GOOD;
        for (var i = 0; i < count; i++) {
            var val = (history[i] as Lang.Float).toFloat();
            var readingSecs;
            if (timestamps != null && i < timestamps.size()) {
                readingSecs = (timestamps[i] as Lang.Number).toLong();
            } else {
                readingSecs = latestSecs - ((count - 1 - i).toLong() * 300l);
            }
            var secsAgo = nowSecs - readingSecs;
            var xRatio = 1.0f - secsAgo.toFloat() / windowSecs.toFloat();
            if (xRatio < 0.0f || xRatio > 1.0f) { continue; }
            var x = margin + (xRatio * plotWidth).toNumber();
            var yRatio = (val - loVal) / valRange;
            if (yRatio < 0.0f) { yRatio = 0.0f; }
            if (yRatio > 1.0f) { yRatio = 1.0f; }
            var y = plotBottom - (yRatio * plotHeight).toNumber();
            dc.setColor(glucoseColorDim(val), Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x, y, 5);
            lastDotX = x;
            lastDotY = y;
            lastDotColor = glucoseColor(val);
        }

        if (lastDotX >= 0) {
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(lastDotX, lastDotY, 9);
            dc.setColor(lastDotColor, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(lastDotX, lastDotY, 5);
            dc.setColor(lastDotColor, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(1);
            dc.drawCircle(lastDotX, lastDotY, 8);
        }

        drawLeftLabel(dc, mmolMax.format("%.1f"), maxX, plotTop + 7);
        drawLeftLabel(dc, mmolMin.format("%.1f"), minX, plotBottom - 7);
    }

    hidden function formatThousands(n as Lang.Number) as Lang.String {
        var s = n.toString();
        var len = s.length();
        var result = "";
        for (var i = 0; i < len; i++) {
            if (i > 0 && (len - i) % 3 == 0) {
                result += ",";
            }
            result += s.substring(i, i + 1);
        }
        return result;
    }

    hidden function circleInnerLeftX(cx as Lang.Number, cy as Lang.Number, r as Lang.Number, y as Lang.Number, innerMargin as Lang.Number) as Lang.Number {
        var dy = (y - cy).abs();
        if (dy >= r) { return cx; }
        var dx = Math.sqrt(((r * r - dy * dy)).toFloat()).toNumber();
        return cx - dx + innerMargin;
    }

    hidden function circleInnerRightX(cx as Lang.Number, cy as Lang.Number, r as Lang.Number, y as Lang.Number, innerMargin as Lang.Number) as Lang.Number {
        var dy = (y - cy).abs();
        if (dy >= r) { return cx; }
        var dx = Math.sqrt(((r * r - dy * dy)).toFloat()).toNumber();
        return cx + dx - innerMargin;
    }

    hidden function drawLeftLabel(dc as Graphics.Dc, text as Lang.String, x as Lang.Number, y as Lang.Number) as Void {
        dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_XTINY, text,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    hidden function glucoseColor(mmol as Lang.Float) as Graphics.ColorType {
        if (mmol < 4.0f) { return COLOR_LOW; }
        if (mmol > 7.0f) { return COLOR_HIGH; }
        return COLOR_GOOD;
    }

    hidden function glucoseColorDim(mmol as Lang.Float) as Graphics.ColorType {
        if (mmol < 4.0f) { return COLOR_LOW_DIM; }
        if (mmol > 7.0f) { return COLOR_HIGH_DIM; }
        return COLOR_GOOD_DIM;
    }
}
