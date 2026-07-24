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
    // Without this, a changed Setting (e.g. GlucoseUnit, Language) isn't picked up
    // until the next natural onUpdate tick — up to a minute away, longer still if
    // the device is showing a partial/always-on update in between full redraws.
    function onSettingsChanged() as Void {
        WatchUi.requestUpdate();
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

        var rawSecretProp = Application.Properties.getValue("RawSecret");
        var rawSecret = (rawSecretProp instanceof Lang.Boolean) && (rawSecretProp as Lang.Boolean);
        var token = rawSecret ? secret : sha1Hex(secret);

        var oneHourAgoMs = (Time.now().value() - 3600).toLong() * 1000;
        Communications.makeWebRequest(
            url + "/api/v1/entries/sgv.json",
            {
                "find[date][$gte]" => oneHourAgoMs,
                "count" => 13,
                "token" => token
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
                    // Present only if the CGM source uploads its own trend (Dexcom/xDrip/Libre
                    // typically do); absent for e.g. manual entries. Null falls back to no arrow.
                    var direction = latest["direction"];
                    Application.Storage.setValue("cgmDirection", direction instanceof Lang.String ? direction : null);

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

    const COLOR_GOOD = 0x4CAF50;     // muted green — in range / battery ok
    const COLOR_HIGH = 0xFFB300;     // muted amber — high / battery mid
    const COLOR_LOW = 0xE84C3D;      // muted red — low / battery critical
    const COLOR_GOOD_DIM = 0x1E4620;
    const COLOR_HIGH_DIM = 0x664400;
    const COLOR_LOW_DIM = 0x662018;

    // Very-low/very-high are deliberately more saturated than the muted palette
    // above — these are alarm states, not just out-of-range, so they should read
    // as more urgent than plain LOW/HIGH at a glance.
    const COLOR_VERY_LOW = 0xFF1744;   // vivid red
    const COLOR_VERY_HIGH = 0xFFEB3B;  // bright yellow — distinct hue from amber HIGH
    const COLOR_VERY_LOW_DIM = 0x4D0710;
    const COLOR_VERY_HIGH_DIM = 0x665C00;

    // All layout coordinates below were tuned by eye against the fr970's 454x454
    // screen. Other devices (e.g. fenix 6 at 240-280px) get the same layout
    // proportionally scaled via `scale = screenWidth / REF_SCREEN_SIZE` — see
    // scalePx/scalePen. Fonts are NOT scaled: Toybox system fonts already ship
    // device-appropriate absolute pixel sizes, so symbolic font constants
    // (FONT_XTINY, FONT_NUMBER_MILD, ...) are used as-is on every device.
    const REF_SCREEN_SIZE = 454.0f;

    // On-watch text has no native Garmin locale to hang off (Kazakh isn't a
    // selectable device/Companion App system language, so an iq:language +
    // resources-kaz strings.xml would never be picked automatically — see
    // memory/commit history for the same issue with Russian). Instead this is
    // a manual "Language" app Setting (0=English, 1=Kazakh Cyrillic, 2=Kazakh
    // Latin; see properties.xml) and these tables are indexed by langMode
    // (from getLangMode()) at draw time.
    // NOTE: Kazakh strings below are a best-effort machine translation, not
    // reviewed by a native speaker — verify before shipping. The Latin column
    // follows the 2021 Qazaq Latin orthography (ä, ğ, ñ, ö, q, ş, ū, ü) as I
    // understand it; Kazakhstan's Latin spelling has changed more than once,
    // so this is the part most likely to need a native-speaker correction.
    const DAYS_EN = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const DAYS_KK = ["Жс", "Дс", "Сс", "Ср", "Бс", "Жм", "Сб"];
    const DAYS_KK_LATIN = ["Js", "Ds", "Ss", "Sr", "Bs", "Jm", "Sb"];
    const DAYS_BY_LANG = [DAYS_EN, DAYS_KK, DAYS_KK_LATIN];

    const MONTHS_EN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    const MONTHS_KK = ["Қаң", "Ақп", "Нау", "Сәу", "Мам", "Мау",
                       "Шіл", "Там", "Қыр", "Қаз", "Қар", "Жел"];
    const MONTHS_KK_LATIN = ["Qañ", "Aqp", "Nau", "Säu", "Mam", "Mau",
                       "Şil", "Tam", "Qyr", "Qaz", "Qar", "Jel"];
    const MONTHS_BY_LANG = [MONTHS_EN, MONTHS_KK, MONTHS_KK_LATIN];

    const TICK_LABELS_EN = ["-45m", "-30m", "-15m"];
    const TICK_LABELS_KK = ["-45м", "-30м", "-15м"];
    // Latin "min" abbreviates to the same single letter as English, so this
    // matches TICK_LABELS_EN exactly — kept as its own named constant anyway
    // so a future edit to one doesn't have to remember they're aliased.
    const TICK_LABELS_KK_LATIN = ["-45m", "-30m", "-15m"];
    const TICK_LABELS_BY_LANG = [TICK_LABELS_EN, TICK_LABELS_KK, TICK_LABELS_KK_LATIN];

    const BPM_LABELS = ["bpm", "соқ", "soq"];
    const STEPS_LABELS = ["steps", "қадам", "qadam"];
    const MIN_AGO_LABELS = [" min ago", " мин бұрын", " min buryn"];

    function initialize() { WatchFace.initialize(); }

    // 0=English (default/fallback), 1=Kazakh Cyrillic, 2=Kazakh Latin.
    hidden function getLangMode() as Lang.Number {
        var lang = Application.Properties.getValue("Language");
        if (!(lang instanceof Lang.Number) || lang < 0 || lang > 2) { return 0; }
        return lang;
    }

    hidden function getUse12Hour() as Lang.Boolean {
        var v = Application.Properties.getValue("Use12Hour");
        return (v instanceof Lang.Boolean) && (v as Lang.Boolean);
    }

    // 0=mmol/L (default/fallback), 1=mg/dL. Storage/history/thresholds always stay
    // in mmol/L (see NightscoutDelegate); this only controls display formatting.
    hidden function getUnitMode() as Lang.Number {
        var unit = Application.Properties.getValue("GlucoseUnit");
        if (!(unit instanceof Lang.Number) || unit < 0 || unit > 1) { return 0; }
        return unit;
    }

    // 0=fixed-interval (30min regression / 15min lookback, default/fallback),
    // 1=Nightscout style with computed arrow (consecutive-reading slope, matching
    // bgnow.js's delta logic), 2=Nightscout style with device-reported arrow
    // (uses the CGM source's own "direction" field instead of computing a slope —
    // this is what Nightscout itself actually displays, see direction.js).
    hidden function getTrendCalcMode() as Lang.Number {
        var mode = Application.Properties.getValue("TrendCalcMode");
        if (!(mode instanceof Lang.Number) || mode < 0 || mode > 2) { return 0; }
        return mode;
    }

    hidden function formatGlucose(mmol as Lang.Float, unitMode as Lang.Number) as Lang.String {
        if (unitMode == 1) { return (mmol * 18.0f).format("%.0f"); }
        return mmol.format("%.1f");
    }

    hidden function formatDelta(delta as Lang.Float, unitMode as Lang.Number) as Lang.String {
        var val = unitMode == 1 ? delta * 18.0f : delta;
        var text = val.format(unitMode == 1 ? "%.0f" : "%.1f");
        return (val >= 0.0f ? "+" : "") + text;
    }

    hidden function toFloatOrDefault(v, def as Lang.Float) as Lang.Float {
        if (v instanceof Lang.Float) { return v; }
        if (v instanceof Lang.Number) { return v.toFloat(); }
        return def;
    }

    // Zone thresholds are always mmol/L (matches internal storage — see
    // NightscoutDelegate) regardless of the display GlucoseUnit setting, so the
    // color math below never needs to care which unit the user sees numbers in.
    // Clamped into ascending order in case a user enters them out of sequence.
    hidden function getThresholds() as Lang.Dictionary {
        var veryLow = toFloatOrDefault(Application.Properties.getValue("VeryLowThreshold"), 3.0f);
        var low = toFloatOrDefault(Application.Properties.getValue("LowThreshold"), 4.0f);
        var high = toFloatOrDefault(Application.Properties.getValue("HighThreshold"), 7.0f);
        var veryHigh = toFloatOrDefault(Application.Properties.getValue("VeryHighThreshold"), 10.0f);
        if (low < veryLow) { low = veryLow; }
        if (high < low) { high = low; }
        if (veryHigh < high) { veryHigh = high; }
        return { :veryLow => veryLow, :low => low, :high => high, :veryHigh => veryHigh };
    }

    hidden function scalePx(v as Lang.Number, scale as Lang.Float) as Lang.Number {
        return (v * scale).toNumber();
    }

    // Like scalePx but floors at 1 so stroke widths/corner radii never vanish
    // on much smaller screens.
    hidden function scalePen(v as Lang.Number, scale as Lang.Float) as Lang.Number {
        var result = (v * scale).toNumber();
        return result < 1 ? 1 : result;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;
        var r = cx - 3;
        var scale = w.toFloat() / REF_SCREEN_SIZE;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // Battery (top center)
        var battery = System.getSystemStats().battery.toNumber();
        var batBodyW = scalePx(36, scale); var batBodyH = scalePx(18, scale);
        var batTipW = scalePx(5, scale); var batTipH = scalePx(11, scale);
        var batText = battery + "%";
        var batTextW = dc.getTextWidthInPixels(batText, Graphics.FONT_XTINY);
        var batGap = scalePx(7, scale);
        var batGroupX = cx - (batBodyW + batTipW + batGap + batTextW) / 2;
        var batX = batGroupX;
        var batYCenter = scalePx(38, scale);
        var batY = batYCenter - batBodyH / 2;
        var batR = scalePx(3, scale);
        var batFillColor = battery <= 20 ? COLOR_LOW : (battery <= 50 ? COLOR_HIGH : COLOR_GOOD);
        dc.setColor(batFillColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(scalePen(2, scale));
        dc.drawRoundedRectangle(batX, batY, batBodyW, batBodyH, batR);
        dc.fillRoundedRectangle(batX + batBodyW, batY + (batBodyH - batTipH) / 2, batTipW, batTipH, scalePx(2, scale));
        dc.setPenWidth(1);
        var batBorder = scalePx(3, scale);
        var batFillW = ((batBodyW - batBorder * 2) * battery / 100).toNumber();
        if (batFillW > 0) {
            dc.fillRoundedRectangle(batX + batBorder, batY + batBorder, batFillW, batBodyH - batBorder * 2, batR - 1);
        }
        dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(batGroupX + batBodyW + batTipW + batGap, batYCenter, Graphics.FONT_XTINY, batText,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Date (AM/PM, when enabled, rides along on this line rather than squeezing
        // into the clock row — the clock's own digits already reach close to the HR/steps
        // columns at x=87/w-87 with barely any slack on either side, confirmed by measuring
        // real pixel overlap at every shift amount tried; the date line has genuine unused
        // horizontal room by comparison, verified safe in both English and Kazakh)
        var langMode = getLangMode();
        var clockTime = System.getClockTime();
        var use12Hour = getUse12Hour();
        var ampmText = clockTime.hour < 12 ? "AM" : "PM";
        var info = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var days = DAYS_BY_LANG[langMode];
        var months = MONTHS_BY_LANG[langMode];
        var dateText = days[info.day_of_week - 1] + " " + info.day + " " + months[info.month - 1];
        if (use12Hour) { dateText += " " + ampmText; }
        dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, scalePx(66, scale), Graphics.FONT_XTINY, dateText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Time (center; nudged left for Kazakh since the longer steps label sits closer to center)
        var timeText;
        if (use12Hour) {
            var hour12 = clockTime.hour % 12;
            if (hour12 == 0) { hour12 = 12; }
            timeText = hour12.format("%d") + ":" + clockTime.min.format("%02d");
        } else {
            timeText = clockTime.hour.format("%02d") + ":" + clockTime.min.format("%02d");
        }
        var yTime = scalePx(133, scale);
        var xTime = langMode != 0 ? cx - scalePx(14, scale) : cx;
        dc.setColor(COLOR_TEXT_PRIMARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(xTime, yTime, Graphics.FONT_NUMBER_MILD, timeText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Heart rate (left of time)
        var actInfo = Activity.getActivityInfo();
        var hr = actInfo != null ? actInfo.currentHeartRate : null;
        var xHr = scalePx(87, scale);
        var hrLabelOffset = scalePx(8, scale);
        var hrUnitOffset = scalePx(14, scale);
        dc.setColor(COLOR_TEXT_SECONDARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(xHr, yTime - hrLabelOffset, Graphics.FONT_XTINY,
            hr != null ? hr.toString() : "--",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(xHr, yTime + hrUnitOffset, Graphics.FONT_XTINY, BPM_LABELS[langMode],
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Steps (right of time)
        var xSteps = w - scalePx(87, scale);
        var actMonInfo = ActivityMonitor.getInfo();
        var steps = actMonInfo != null ? actMonInfo.steps : null;
        dc.setColor(COLOR_TEXT_SECONDARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(xSteps, yTime - hrLabelOffset, Graphics.FONT_XTINY,
            steps != null ? steps.toString() : "--",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(xSteps, yTime + hrUnitOffset, Graphics.FONT_XTINY, STEPS_LABELS[langMode],
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // CGM data
        var history = Application.Storage.getValue("cgmHistory") as Lang.Array?;
        var timestamps = Application.Storage.getValue("cgmTimestamps") as Lang.Array?;
        var dateMs = Application.Storage.getValue("cgmDate") as Lang.Long?;
        var mmol = Application.Storage.getValue("cgmMmol") as Lang.Float?;

        var showChartProp = Application.Properties.getValue("ShowChart");
        var showChart = !(showChartProp instanceof Lang.Boolean) || (showChartProp as Lang.Boolean);

        var unitMode = getUnitMode();
        var thresholds = getThresholds();
        var trendCalcMode = getTrendCalcMode();
        if (showChart) {
            if (history != null && history.size() > 0 && dateMs != null) {
                drawScatterPlot(dc, history, timestamps, w, h, dateMs, scale, {
                    :langMode => langMode, :unitMode => unitMode, :thresholds => thresholds
                });
            }
            // CGM value + trend (bottom)
            var yCgm = scalePx(373, scale);
            if (mmol != null && dateMs != null) {
                drawCgmBlock(dc, cx, yCgm, mmol, dateMs, history, timestamps, {
                    :valueFont => Graphics.FONT_NUMBER_MILD, :arrowScale => 0.85f * scale, :arrowGap => scalePx(6, scale),
                    :labelFont => Graphics.FONT_XTINY, :minAgoYOffset => scalePx(47, scale), :langMode => langMode,
                    :unitMode => unitMode, :thresholds => thresholds, :trendCalcMode => trendCalcMode
                });
            } else {
                dc.setColor(COLOR_TEXT_SECONDARY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, yCgm, Graphics.FONT_NUMBER_MILD, "--",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        } else {
            // Value-only mode: one large readout filling the space the chart +
            // compact value block would otherwise occupy (y~178-419), pulled up
            // close under the time/steps row rather than centered in that span.
            var yBig = scalePx(272, scale);
            if (mmol != null && dateMs != null) {
                drawCgmBlock(dc, cx, yBig, mmol, dateMs, history, timestamps, {
                    :valueFont => Graphics.FONT_NUMBER_THAI_HOT, :arrowScale => 1.5f * scale, :arrowGap => scalePx(12, scale),
                    :labelFont => Graphics.FONT_MEDIUM, :minAgoYOffset => scalePx(96, scale), :langMode => langMode,
                    :unitMode => unitMode, :thresholds => thresholds, :trendCalcMode => trendCalcMode
                });
            } else {
                dc.setColor(COLOR_TEXT_SECONDARY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, yBig, Graphics.FONT_NUMBER_THAI_HOT, "--",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        }
    }

    // Draws glucose value + trend arrow + delta + "X min ago", vertically centered
    // on yValue. Arrow+delta placement is derived from actual font/glyph metrics
    // (not fixed pixel offsets) so the pair stays centered on and bounded by the
    // value's own height at any font size — same logic serves both the compact
    // chart-mode readout and the large value-only-mode readout.
    // `style` keys: :valueFont, :arrowScale, :arrowGap, :labelFont, :minAgoYOffset, :langMode,
    // :unitMode, :thresholds, :trendCalcMode —
    // bundled into a Dictionary because some devices (e.g. fenix 6, older VM) cap
    // function calls at 9 arguments; passing the params separately blew past that.
    hidden function drawCgmBlock(dc as Graphics.Dc, cx as Lang.Number, yValue as Lang.Number,
            mmol as Lang.Float, dateMs as Lang.Long, history as Lang.Array?, timestamps as Lang.Array?,
            style as Lang.Dictionary) as Void {
        var valueFont = style[:valueFont] as Graphics.FontType;
        var arrowScale = style[:arrowScale] as Lang.Float;
        var arrowGap = style[:arrowGap] as Lang.Number;
        var labelFont = style[:labelFont] as Graphics.FontType;
        var minAgoYOffset = style[:minAgoYOffset] as Lang.Number;
        var langMode = style[:langMode] as Lang.Number;
        var unitMode = style[:unitMode] as Lang.Number;
        var thresholds = style[:thresholds] as Lang.Dictionary;
        var trendCalcMode = style[:trendCalcMode] as Lang.Number;
        var minsAgo = ((Time.now().value() - dateMs.toLong() / 1000l) / 60).toNumber();

        var trend = null;
        var delta = null;
        if (history != null && timestamps != null && history.size() > 0) {
            if (trendCalcMode == 2) {
                var directionStr = Application.Storage.getValue("cgmDirection") as Lang.String?;
                trend = directionToTrend(directionStr);
                delta = computeDeltaConsecutive(history, timestamps, mmol);
            } else if (trendCalcMode == 1) {
                var slope = computeTrendSlopeConsecutive(history, timestamps);
                if (slope != null) { trend = slopeToTrend(slope); }
                delta = computeDeltaConsecutive(history, timestamps, mmol);
            } else {
                var slope = computeTrendSlope(history, timestamps);
                if (slope != null) { trend = slopeToTrend(slope); }
                delta = computeDelta15(history, timestamps, mmol);
            }
        }

        var valueText = formatGlucose(mmol, unitMode);
        var cgmColor = glucoseColor(mmol, thresholds);
        dc.setColor(cgmColor, Graphics.COLOR_TRANSPARENT);
        if (trend != null) {
            var valueW = dc.getTextWidthInPixels(valueText, valueFont);
            var arrowW = (34 * arrowScale).toNumber();
            var deltaText = "";
            var colW = arrowW;
            if (delta != null) {
                deltaText = formatDelta(delta as Lang.Float, unitMode);
                var deltaW = dc.getTextWidthInPixels(deltaText, labelFont);
                // The column is sized by whichever is wider — the arrow glyph or the
                // delta text — so neither one crowds into the value's digits.
                if (deltaW > colW) { colW = deltaW; }
            }
            var groupLeft = cx - (valueW + arrowGap + colW) / 2;
            var arrowCx = groupLeft + valueW + arrowGap + colW / 2;
            dc.drawText(groupLeft, yValue, valueFont, valueText,
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            // drawTrendArrow's tallest glyphs (up/down) span roughly ±21*scale from
            // their center — used as the arrow's half-height for stacking below.
            var arrowHalfH = (21 * arrowScale).toNumber();
            if (delta != null) {
                var labelFontHeight = dc.getFontHeight(labelFont);
                var stackGap = (labelFontHeight * 0.15).toNumber();
                var stackHeight = arrowHalfH * 2 + stackGap + labelFontHeight;
                var stackTop = yValue - stackHeight / 2;
                var arrowCy = stackTop + arrowHalfH;
                var deltaCy = stackTop + arrowHalfH * 2 + stackGap + labelFontHeight / 2;
                drawTrendArrow(dc, trend as Lang.Number, arrowCx, arrowCy, cgmColor, arrowScale);
                dc.setColor(COLOR_TEXT_SECONDARY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(arrowCx, deltaCy, labelFont, deltaText,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            } else {
                drawTrendArrow(dc, trend as Lang.Number, arrowCx, yValue, cgmColor, arrowScale);
            }
        } else {
            dc.drawText(cx, yValue, valueFont, valueText,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // Stale data (>20 min old) is flagged in the same red used for low glucose,
        // so a silently-dead Nightscout connection reads as an alert, not a footnote.
        dc.setColor(minsAgo > 20 ? COLOR_LOW : COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
        // Cyrillic "мин бұрын" is wide enough that at labelFont size (esp. in
        // value-only mode's FONT_MEDIUM) a 3-digit minute count can clip against
        // the bezel; step down font size until it fits rather than tuning per-string.
        var minAgoText = minsAgo + MIN_AGO_LABELS[langMode];
        var minAgoFont = labelFont;
        var maxMinAgoW = dc.getWidth() * 0.74;
        if (dc.getTextWidthInPixels(minAgoText, minAgoFont) > maxMinAgoW) {
            minAgoFont = Graphics.FONT_SMALL;
        }
        if (dc.getTextWidthInPixels(minAgoText, minAgoFont) > maxMinAgoW) {
            minAgoFont = Graphics.FONT_XTINY;
        }
        dc.drawText(cx, yValue + minAgoYOffset, minAgoFont, minAgoText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
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

    // Nightscout style: latest reading minus the immediately preceding one
    // (mirrors bgnow.js's bucket delta), scaled to a 5-minute-equivalent if the
    // gap between them exceeds 9 minutes so a sensor dropout doesn't show a huge jump.
    hidden function computeDeltaConsecutive(history as Lang.Array, timestamps as Lang.Array, latestVal as Lang.Float) as Lang.Float? {
        var count = timestamps.size();
        if (count < 2 || history.size() < count) { return null; }

        var recentSecs = timestamps[count - 1] as Lang.Number;
        var prevSecs = timestamps[count - 2] as Lang.Number;
        var elapsedMins = (recentSecs - prevSecs).toFloat() / 60.0f;
        if (elapsedMins <= 0.0f) { return null; }

        var absolute = latestVal - (history[count - 2] as Lang.Float).toFloat();
        if (elapsedMins > 9.0f) { return absolute / elapsedMins * 5.0f; }
        return absolute;
    }

    // Nightscout style: slope between the two most recent consecutive readings
    // only, rather than a regression over a fixed rolling window.
    hidden function computeTrendSlopeConsecutive(history as Lang.Array, timestamps as Lang.Array) as Lang.Float? {
        var count = history.size();
        if (count < 2 || timestamps.size() < count) { return null; }

        var nowSecs = Time.now().value().toNumber();
        var latestSecs = timestamps[count - 1] as Lang.Number;
        if (nowSecs - latestSecs > 1200) { return null; }

        var prevSecs = timestamps[count - 2] as Lang.Number;
        var elapsedMins = (latestSecs - prevSecs).toFloat() / 60.0f;
        if (elapsedMins <= 0.0f) { return null; }

        var deltaVal = (history[count - 1] as Lang.Float).toFloat() - (history[count - 2] as Lang.Float).toFloat();
        return deltaVal / elapsedMins;
    }

    // Maps Nightscout's own "direction" string — already computed upstream by the
    // CGM source (Dexcom/xDrip/Libre) and passed through unchanged by Nightscout's
    // own direction.js — onto this app's -3..3 trend scale. Null/NONE/NOT COMPUTABLE/
    // RATE OUT OF RANGE/unrecognized all collapse to null (no arrow shown), same as
    // a null slope from the computed modes.
    hidden function directionToTrend(direction as Lang.String?) as Lang.Number? {
        if (direction == null) { return null; }
        if (direction.equals("TripleUp") || direction.equals("DoubleUp")) { return 3; }
        if (direction.equals("SingleUp")) { return 2; }
        if (direction.equals("FortyFiveUp")) { return 1; }
        if (direction.equals("Flat")) { return 0; }
        if (direction.equals("FortyFiveDown")) { return -1; }
        if (direction.equals("SingleDown")) { return -2; }
        if (direction.equals("DoubleDown") || direction.equals("TripleDown")) { return -3; }
        return null;
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

    hidden function drawScatterPlot(dc as Graphics.Dc, history as Lang.Array, timestamps as Lang.Array?, w as Lang.Number, h as Lang.Number, latestDateMs as Lang.Long, scale as Lang.Float, style as Lang.Dictionary) as Void {
        var langMode = style[:langMode] as Lang.Number;
        var unitMode = style[:unitMode] as Lang.Number;
        var thresholds = style[:thresholds] as Lang.Dictionary;
        var cx = w / 2;
        var cy = h / 2;
        var r = cx - 3;
        var plotBottom = scalePx(308, scale);
        var plotTop = scalePx(178, scale);
        // plotBottom is farther from screen center than plotTop, so it's the tightest row —
        // basing the margin on it keeps both plot edges as close to the circle as safely possible
        var margin = circleInnerLeftX(cx, cy, r, plotBottom, scalePx(6, scale));
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
        var labelPad = scalePx(7, scale);
        var lineGap = scalePx(5, scale);
        var maxX = circleInnerLeftX(cx, cy, r, plotTop + labelPad, lineGap);
        var minX = circleInnerLeftX(cx, cy, r, plotBottom - labelPad, lineGap);
        var maxLabelW = dc.getTextWidthInPixels(formatGlucose(mmolMax, unitMode), Graphics.FONT_XTINY);
        var minLabelW = dc.getTextWidthInPixels(formatGlucose(mmolMin, unitMode), Graphics.FONT_XTINY);
        dc.setColor(COLOR_GRID_LINE, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(maxX + maxLabelW + lineGap, yMax, margin + plotWidth, yMax);
        dc.drawLine(minX + minLabelW + lineGap, yMin, margin + plotWidth, yMin);

        var tickMins = [45, 30, 15];
        var tickLabels = TICK_LABELS_BY_LANG[langMode];
        var tickLabelOffset = scalePx(14, scale);
        for (var t = 0; t < 3; t++) {
            var xTick = margin + ((1.0f - tickMins[t] * 60.0f / windowSecs.toFloat()) * plotWidth).toNumber();
            dc.setColor(COLOR_GRID_LINE, Graphics.COLOR_TRANSPARENT);
            dc.drawLine(xTick, plotTop, xTick, plotBottom);
            dc.setColor(COLOR_TEXT_TERTIARY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(xTick, plotBottom + tickLabelOffset, Graphics.FONT_XTINY, tickLabels[t],
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
            dc.setColor(glucoseColorDim(val, thresholds), Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x, y, scalePx(7, scale));
            lastDotX = x;
            lastDotY = y;
            lastDotColor = glucoseColor(val, thresholds);
        }

        if (lastDotX >= 0) {
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(lastDotX, lastDotY, scalePx(11, scale));
            dc.setColor(lastDotColor, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(lastDotX, lastDotY, scalePx(7, scale));
            dc.setColor(lastDotColor, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(scalePen(3, scale));
            dc.drawCircle(lastDotX, lastDotY, scalePx(10, scale));
            dc.setPenWidth(1);
        }

        drawLeftLabel(dc, formatGlucose(mmolMax, unitMode), maxX, plotTop + labelPad);
        drawLeftLabel(dc, formatGlucose(mmolMin, unitMode), minX, plotBottom - labelPad);
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

    hidden function glucoseColor(mmol as Lang.Float, thresholds as Lang.Dictionary) as Graphics.ColorType {
        if (mmol < (thresholds[:veryLow] as Lang.Float)) { return COLOR_VERY_LOW; }
        if (mmol < (thresholds[:low] as Lang.Float)) { return COLOR_LOW; }
        if (mmol > (thresholds[:veryHigh] as Lang.Float)) { return COLOR_VERY_HIGH; }
        if (mmol > (thresholds[:high] as Lang.Float)) { return COLOR_HIGH; }
        return COLOR_GOOD;
    }

    hidden function glucoseColorDim(mmol as Lang.Float, thresholds as Lang.Dictionary) as Graphics.ColorType {
        if (mmol < (thresholds[:veryLow] as Lang.Float)) { return COLOR_VERY_LOW_DIM; }
        if (mmol < (thresholds[:low] as Lang.Float)) { return COLOR_LOW_DIM; }
        if (mmol > (thresholds[:veryHigh] as Lang.Float)) { return COLOR_VERY_HIGH_DIM; }
        if (mmol > (thresholds[:high] as Lang.Float)) { return COLOR_HIGH_DIM; }
        return COLOR_GOOD_DIM;
    }
}
