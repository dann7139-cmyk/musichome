/**
 * AdminReportsScreen — 📊 Reportes (panel ejecutivo del admin).
 * Diseño aprobado 2026-07-18: el dashboard es la herramienta principal;
 * Excel/PDF son la exportación secundaria (botón arriba a la derecha).
 *
 * Datos: admin_reports_dashboard (sql/504) — fórmulas canónicas de
 * sql/490. Monedas SEPARADAS siempre; cero estimaciones.
 */

import { ArrowLeft, Download } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Linking,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import {
  CountryTabs, COUNTRY_FLAGS, fmtMoney, KpiCard, MetricRow, SectionHeader, TrendBars,
} from '../../components/reports';

// ─── Rangos rápidos de fecha ──────────────────────────────────────────────────
const RANGES = [
  { key: '30d',  label: '30 días',  days: 30 },
  { key: '90d',  label: '90 días',  days: 90 },
  { key: 'year', label: 'Este año', days: 365 },
  { key: 'all',  label: 'Todo',     days: 0 },
];

const MONTH_LABELS = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

function monthLabel(yyyymm: string): string {
  const m = parseInt(yyyymm?.split('-')[1] ?? '1', 10);
  return MONTH_LABELS[(m - 1) % 12] ?? yyyymm;
}

export default function AdminReportsScreen({ navigation }: any) {
  const [country,    setCountry]    = useState<string | null>(null);
  const [range,      setRange]      = useState('90d');
  const [stateFil,   setStateFil]   = useState('');
  const [cityFil,    setCityFil]    = useState('');
  const [data,       setData]       = useState<any | null>(null);
  const [loading,    setLoading]    = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [exporting,  setExporting]  = useState(false);

  const load = useCallback(async () => {
    try {
      const r = RANGES.find(x => x.key === range) ?? RANGES[1];
      const from = r.days > 0
        ? new Date(Date.now() - r.days * 86_400_000).toISOString().slice(0, 10)
        : null;
      const { data: d, error } = await supabase.rpc('admin_reports_dashboard', {
        p_from:    from,
        p_to:      null,
        p_country: country,
        p_state:   stateFil.trim() || null,
        p_city:    cityFil.trim() || null,
      });
      if (error) throw error;
      if (d?.ok) setData(d);
      else if (d?.error) Alert.alert('Error', d.error);
    } catch (e: any) {
      console.error('[AdminReports]', e?.message);
    } finally {
      setLoading(false);
    }
  }, [country, range, stateFil, cityFil]);

  useEffect(() => { load(); }, [load]);

  const onRefresh = async () => { setRefreshing(true); await load(); setRefreshing(false); };

  // ── Exportar: formato → alcance de país → EF generate-report ───────────────
  const handleExport = () => {
    Alert.alert('⬇ Exportar reporte', '¿En qué formato?', [
      { text: 'Cancelar', style: 'cancel' },
      { text: '📊 Excel (.xlsx)', onPress: () => pickExportCountry('xlsx') },
      { text: '📄 PDF ejecutivo', onPress: () => pickExportCountry('pdf') },
    ]);
  };

  const pickExportCountry = (format: 'xlsx' | 'pdf') => {
    Alert.alert('Alcance', '¿Qué país incluye el reporte?', [
      { text: 'Cancelar', style: 'cancel' },
      { text: '🌎 Todos', onPress: () => runExport(format, null) },
      { text: '🇲🇽 Solo México', onPress: () => runExport(format, 'MX') },
      { text: '🇺🇸 Solo EE.UU.', onPress: () => runExport(format, 'US') },
      { text: '🇨🇦 Solo Canadá', onPress: () => runExport(format, 'CA') },
    ]);
  };

  const runExport = async (format: 'xlsx' | 'pdf', cc: string | null) => {
    if (exporting) return;
    setExporting(true);
    try {
      const r = RANGES.find(x => x.key === range) ?? RANGES[1];
      const from = r.days > 0
        ? new Date(Date.now() - r.days * 86_400_000).toISOString().slice(0, 10)
        : '2000-01-01';
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error('Sesión expirada.');
      const { data: res, error } = await supabase.functions.invoke('generate-report', {
        body: {
          mode: 'admin', format,
          country: cc ?? 'all',
          from, to: new Date().toISOString().slice(0, 10),
        },
        headers: { Authorization: `Bearer ${session.access_token}` },
      });
      if (error) throw new Error(error.message ?? 'Error de red');
      if ((res as any)?.error) throw new Error((res as any).error);
      const url = (res as any)?.url as string | undefined;
      if (!url) throw new Error('No se recibió el archivo');
      await Linking.openURL(url);
    } catch (e: any) {
      Alert.alert('Error al exportar', e.message ?? 'Intenta de nuevo.');
    } finally {
      setExporting(false);
    }
  };

  // ── Derivados ───────────────────────────────────────────────────────────────
  const currencies: any[] = data?.currencies ?? [];
  const ev  = data?.events ?? {};
  const com = data?.community ?? {};
  const cancelRate = ev.total > 0 ? Math.round((ev.cancelados / ev.total) * 100) : 0;

  // Tendencia: agrupar por mes (si hay varias monedas, prioriza MXN)
  const trendCurrency = currencies.length === 1 ? currencies[0].moneda : 'MXN';
  const trendData = (data?.trend ?? [])
    .filter((t: any) => t.moneda === trendCurrency)
    .map((t: any) => ({ label: monthLabel(t.mes), value: Number(t.total) }));

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={{ flex: 1 }}>
          <Text style={s.headerTitle}>📊 Reportes</Text>
          <Text style={s.headerSub}>{data ? `${data.from} — ${data.to}` : ' '}</Text>
        </View>
        <Pressable style={[s.exportBtn, exporting && { opacity: 0.6 }]} onPress={handleExport} disabled={exporting}>
          {exporting
            ? <ActivityIndicator size="small" color="#000" />
            : <Download size={14} color="#000" strokeWidth={2.5} />}
          <Text style={s.exportTx}>Exportar</Text>
        </Pressable>
      </SafeAreaView>

      {loading ? (
        <View style={s.center}><ActivityIndicator size="large" color={COLORS.green} /></View>
      ) : (
        <ScrollView
          contentContainerStyle={s.scroll}
          showsVerticalScrollIndicator={false}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {/* ── Filtros ── */}
          <CountryTabs value={country} onChange={setCountry} />
          <View style={s.rangeRow}>
            {RANGES.map(r => (
              <Pressable
                key={r.key}
                style={[s.rangeChip, range === r.key && s.rangeChipOn]}
                onPress={() => setRange(r.key)}
              >
                <Text style={[s.rangeTx, range === r.key && s.rangeTxOn]}>{r.label}</Text>
              </Pressable>
            ))}
          </View>
          <View style={s.filterRow}>
            <TextInput
              style={s.filterInput}
              value={stateFil}
              onChangeText={setStateFil}
              onSubmitEditing={load}
              placeholder="Estado (ej. Jalisco)"
              placeholderTextColor={COLORS.muted}
              returnKeyType="search"
            />
            <TextInput
              style={s.filterInput}
              value={cityFil}
              onChangeText={setCityFil}
              onSubmitEditing={load}
              placeholder="Ciudad"
              placeholderTextColor={COLORS.muted}
              returnKeyType="search"
            />
          </View>

          {/* ── 💰 Dinero por moneda ── */}
          {currencies.length === 0 && (
            <View style={s.emptyBox}>
              <Text style={s.emptyTx}>Sin cobros en este rango y filtros.</Text>
            </View>
          )}
          {currencies.map((cur: any) => (
            <View key={cur.moneda}>
              <SectionHeader
                title={`💰 Dinero · ${cur.moneda}`}
                note={currencies.length > 1 ? 'las monedas nunca se suman' : undefined}
              />
              <View style={s.grid}>
                <KpiCard
                  variant="hero" wide
                  label={`Ingreso bruto · ${cur.moneda}`}
                  value={fmtMoney(cur.total_cobrado)}
                  detail={`${cur.eventos_cobrados} eventos cobrados`}
                />
                <KpiCard
                  variant="gold"
                  label="Ganancia neta Daricefy"
                  value={fmtMoney(cur.neto_estimado)}
                  detail="comisión − procesadores"
                />
                <KpiCard
                  label="Comisión procesadores"
                  value={fmtMoney(cur.fees_reales)}
                  detail={cur.fees_no_capturados > 0 ? `${cur.fees_no_capturados} no capturados` : 'todas reales'}
                  detailColor={cur.fees_no_capturados > 0 ? COLORS.orange : COLORS.green}
                />
                <KpiCard label="Para grupos" value={fmtMoney(cur.dinero_grupos)} />
                <KpiCard
                  label="Pendiente por pagar"
                  value={fmtMoney(cur.pendiente_grupos)}
                  detail="retenido hasta finalizar"
                />
                <KpiCard label="Pagado a grupos" value={fmtMoney(cur.pagado_grupos)} />
                <KpiCard
                  label="Reembolsos"
                  value={fmtMoney(cur.reembolsado)}
                  detail={`${cur.reembolsos} reembolsos`}
                  detailColor={cur.reembolsos > 0 ? COLORS.red : undefined}
                />
              </View>
            </View>
          ))}

          {/* ── 🗓 Eventos ── */}
          <SectionHeader title="🗓 Eventos" />
          <MetricRow icon="🗓" label="Total de eventos" sub="reservas creadas en el rango" value={String(ev.total ?? 0)} />
          <MetricRow
            icon="✅" label="Completados" value={String(ev.completados ?? 0)}
            pill={ev.total > 0 ? { kind: 'ok', label: `${Math.round(((ev.completados ?? 0) / ev.total) * 100)}%` } : undefined}
          />
          <MetricRow icon="⏳" label="Próximos" sub="aceptados con fecha por venir" value={String(ev.proximos ?? 0)} />
          <MetricRow
            icon="🚫" label="Cancelaciones"
            sub={`${ev.cancel_cliente ?? 0} del cliente · ${ev.cancel_grupo ?? 0} del grupo`}
            value={String(ev.cancelados ?? 0)}
            pill={{ kind: cancelRate > 10 ? 'bad' : cancelRate > 5 ? 'warn' : 'ok', label: `${cancelRate}%` }}
          />
          <MetricRow
            icon="👻" label="No-shows" value={String(ev.no_shows ?? 0)}
            pill={(ev.no_shows ?? 0) > 0 ? { kind: 'bad', label: 'strikes' } : { kind: 'ok', label: 'limpio' }}
          />
          <MetricRow icon="↩️" label="Reembolsados" value={String(ev.reembolsados ?? 0)} />

          {/* ── 📈 Tendencia ── */}
          {trendData.length > 1 && (
            <>
              <SectionHeader title="📈 Tendencia mensual" note={`ingreso bruto · ${trendCurrency}`} />
              <TrendBars title="Últimos 6 meses" right={trendCurrency} data={trendData} />
            </>
          )}

          {/* ── 👥 Comunidad por país ── */}
          <SectionHeader title="👥 Comunidad" note="por país — sin mezclar" />
          {(com.grupos ?? []).map((g: any) => (
            <MetricRow
              key={`g-${g.pais}`}
              icon={COUNTRY_FLAGS[g.pais] ?? '🌎'}
              label={`Grupos activos · ${g.pais}`}
              sub={g.nuevos > 0 ? `+${g.nuevos} nuevos en el rango` : 'sin nuevos en el rango'}
              value={String(g.activos)}
            />
          ))}
          {(com.talentos ?? []).map((t: any) => (
            <MetricRow
              key={`t-${t.pais}`}
              icon="🎤"
              label={`Talentos · ${t.pais}`}
              sub={t.nuevos > 0 ? `+${t.nuevos} nuevos en el rango` : undefined}
              value={String(t.activos)}
            />
          ))}
          <MetricRow
            icon="🆕" label="Nuevos registros"
            sub="clientes + grupos + talentos en el rango"
            value={String(com.nuevos_registros ?? 0)}
          />

          <View style={{ height: 40 }} />
        </ScrollView>
      )}
    </View>
  );
}

// ─── Estilos ──────────────────────────────────────────────────────────────────
const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingHorizontal: SPACING.md, paddingBottom: SPACING.sm,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
  headerTitle: { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text },
  headerSub: { fontFamily: FONTS.body, fontSize: 10.5, color: COLORS.muted },
  exportBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingHorizontal: 13, paddingVertical: 9,
  },
  exportTx: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: '#000' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  scroll: { paddingHorizontal: SPACING.md, paddingTop: SPACING.md },

  rangeRow: { flexDirection: 'row', gap: 7, marginTop: 9 },
  rangeChip: {
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card, paddingHorizontal: 11, paddingVertical: 6,
  },
  rangeChipOn: { borderColor: 'rgba(0,230,118,0.5)', backgroundColor: COLORS.greenMuted },
  rangeTx: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },
  rangeTxOn: { color: COLORS.green },

  filterRow: { flexDirection: 'row', gap: 8, marginTop: 9 },
  filterInput: {
    flex: 1, backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 8,
    fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.text,
  },

  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: 9 },

  emptyBox: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 30, alignItems: 'center', marginTop: SPACING.lg,
  },
  emptyTx: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
});
