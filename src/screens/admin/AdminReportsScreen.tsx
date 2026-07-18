/**
 * AdminReportsScreen — 🧠 Centro de Inteligencia de Daricefy.
 * (Cambios aprobados 2026-07-18 sobre el diseño original.)
 *
 * Pestañas (REGISTRO escalable: agregar una pestaña = agregar una
 * entrada a TAB_REGISTRY y su componente — nada más):
 *   Resumen · Finanzas · Eventos · Países · Rankings · Alertas
 *
 * Reglas: monedas SEPARADAS siempre · cero estimaciones · el Exportar
 * baja EXACTAMENTE lo que se está viendo (mismos filtros) · país no
 * definido visible y corregible, nunca inventado.
 *
 * Datos: admin_reports_dashboard (504/505), admin_country_compare,
 * admin_rankings, admin_alerts, admin_pending_country_list (507).
 */

import { ArrowLeft, Download } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Linking,
  Modal,
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
  CountryTabs, COUNTRY_FLAGS, fmtMoney, KpiCard, MetricRow, SectionHeader, StatePicker, TrendBars,
} from '../../components/reports';

// ─── Rangos rápidos ───────────────────────────────────────────────────────────
const RANGES = [
  { key: '30d',  label: '30 días',  days: 30 },
  { key: '90d',  label: '90 días',  days: 90 },
  { key: 'year', label: 'Este año', days: 365 },
  { key: 'all',  label: 'Todo',     days: 0 },
];

// 📑 REGISTRO de pestañas — para crecer sin rediseñar
const TAB_REGISTRY = [
  { key: 'resumen',  label: 'Resumen' },
  { key: 'finanzas', label: 'Finanzas' },
  { key: 'eventos',  label: 'Eventos' },
  { key: 'paises',   label: 'Países' },
  { key: 'rankings', label: 'Rankings' },
  { key: 'alertas',  label: 'Alertas' },
];

const MONTH_LABELS = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
const monthLabel = (yyyymm: string) =>
  MONTH_LABELS[(parseInt(yyyymm?.split('-')[1] ?? '1', 10) - 1) % 12] ?? yyyymm;

const CURRENCY_COUNTRY: Record<string, string> = {
  MXN: '🇲🇽 México', USD: '🇺🇸 Estados Unidos', CAD: '🇨🇦 Canadá',
};
const CC_OF_COUNTRY: Record<string, string> = {
  'México': 'MX', 'Estados Unidos': 'US', 'Canadá': 'CA',
};

export default function AdminReportsScreen({ navigation }: any) {
  const [tab,        setTab]        = useState('resumen');
  const [country,    setCountry]    = useState<string | null>(null);
  const [range,      setRange]      = useState('90d');
  const [stateFil,   setStateFil]   = useState<string | null>(null);
  const [cityFil,    setCityFil]    = useState('');
  const [data,       setData]       = useState<any | null>(null);
  const [compare,    setCompare]    = useState<any | null>(null);
  const [rankings,   setRankings]   = useState<any | null>(null);
  const [alerts,     setAlerts]     = useState<any | null>(null);
  const [loading,    setLoading]    = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [exporting,  setExporting]  = useState(false);
  // 🏳️ Pendientes de clasificar
  const [pendOpen,   setPendOpen]   = useState(false);
  const [pendItems,  setPendItems]  = useState<any[]>([]);

  const fromDate = useCallback(() => {
    const r = RANGES.find(x => x.key === range) ?? RANGES[1];
    return r.days > 0
      ? new Date(Date.now() - r.days * 86_400_000).toISOString().slice(0, 10)
      : null;
  }, [range]);

  const load = useCallback(async () => {
    try {
      const from = fromDate();
      const [dRes, cRes, rRes, aRes] = await Promise.all([
        supabase.rpc('admin_reports_dashboard', {
          p_from: from, p_to: null, p_country: country,
          p_state: stateFil, p_city: cityFil.trim() || null,
        }),
        supabase.rpc('admin_country_compare', { p_from: from, p_to: null }),
        supabase.rpc('admin_rankings', {
          p_from: from, p_to: null, p_country: country, p_state: stateFil, p_limit: 5,
        }),
        supabase.rpc('admin_alerts'),
      ]);
      if (dRes.data?.ok) setData(dRes.data);
      if (cRes.data?.ok) setCompare(cRes.data);
      if (rRes.data?.ok) setRankings(rRes.data);
      if (aRes.data?.ok) setAlerts(aRes.data);
      const err = dRes.error ?? cRes.error ?? rRes.error ?? aRes.error;
      if (err) console.warn('[Reportes]', err.message);
    } finally {
      setLoading(false);
    }
  }, [country, range, stateFil, cityFil, fromDate]);

  useEffect(() => { load(); }, [load]);
  const onRefresh = async () => { setRefreshing(true); await load(); setRefreshing(false); };

  // ── 🏳️ Pendientes de clasificar ─────────────────────────────────────────────
  const openPending = async () => {
    const { data: d } = await supabase.rpc('admin_pending_country_list');
    setPendItems(d?.ok ? (d.items ?? []) : []);
    setPendOpen(true);
  };

  const assignCountry = (item: any) => {
    const doSet = async (co: string) => {
      const { data: r } = await supabase.rpc('admin_set_country', {
        p_entity: item.entity, p_id: item.id, p_country: co,
      });
      if (r?.ok) {
        setPendItems(prev => prev.filter(x => x.id !== item.id));
        load();
      } else {
        Alert.alert('Error', r?.error ?? 'No se pudo asignar');
      }
    };
    Alert.alert(`🏳️ ${item.name}`, '¿A qué país pertenece?', [
      { text: 'Cancelar', style: 'cancel' },
      { text: '🇲🇽 México', onPress: () => doSet('México') },
      { text: '🇺🇸 Estados Unidos', onPress: () => doSet('Estados Unidos') },
      { text: '🇨🇦 Canadá', onPress: () => doSet('Canadá') },
    ]);
  };

  // ── ⬇ Exportar — EXACTAMENTE lo que se está viendo ─────────────────────────
  const handleExport = () => {
    const scope = country ? `${COUNTRY_FLAGS[country] ?? ''} ${country}` : '🌎 Todos';
    const stateTx = stateFil ? ` · ${stateFil}` : '';
    Alert.alert(
      '⬇ Exportar',
      `Se exporta lo que estás viendo:\n${scope}${stateTx} · ${RANGES.find(r => r.key === range)?.label}`,
      [
        { text: 'Cancelar', style: 'cancel' },
        { text: '📊 Excel (.xlsx)', onPress: () => runExport('xlsx') },
        { text: '📄 PDF ejecutivo', onPress: () => runExport('pdf') },
      ],
    );
  };

  const runExport = async (format: 'xlsx' | 'pdf') => {
    if (exporting) return;
    setExporting(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error('Sesión expirada.');
      const { data: res, error } = await supabase.functions.invoke('generate-report', {
        body: {
          mode: 'admin', format,
          country: country ? (CC_OF_COUNTRY[country] ?? 'all') : 'all',
          state:   stateFil,
          from:    fromDate() ?? '2000-01-01',
          to:      new Date().toISOString().slice(0, 10),
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
  const trendCurrency = currencies.length === 1 ? currencies[0].moneda : 'MXN';
  const trendData = (data?.trend ?? [])
    .filter((t: any) => t.moneda === trendCurrency)
    .map((t: any) => ({ label: monthLabel(t.mes), value: Number(t.total) }));

  const pendTotal = (compare?.pendientes?.grupos ?? 0) + (compare?.pendientes?.talentos ?? 0);
  const alertCount = alerts
    ? ['retiros_pendientes', 'fees_no_capturados', 'sin_pais', 'grupos_suspendidos',
       'disputas_abiertas', 'reembolsos_pendientes', 'eventos_sin_cerrar', 'pagos_retenidos_viejos']
        .reduce((s, k) => s + (Number(alerts[k]) > 0 ? 1 : 0), 0)
    : 0;

  const empty = (msg: string, hint?: string) => (
    <View style={s.emptyBox}>
      <Text style={s.emptyTx}>{msg}</Text>
      {!!hint && <Text style={s.emptyHint}>{hint}</Text>}
    </View>
  );

  // ── Bloques reutilizables ───────────────────────────────────────────────────
  const moneyBlock = (compact: boolean) => (
    currencies.length === 0
      ? empty('Sin cobros en este rango y filtros.', 'Prueba el rango "Todo" o quita filtros.')
      : currencies.map((cur: any) => (
        <View key={cur.moneda}>
          <SectionHeader
            title={`💰 ${CURRENCY_COUNTRY[cur.moneda] ?? cur.moneda} · ${cur.moneda}`}
            note={currencies.length > 1 ? 'las monedas nunca se suman' : undefined}
          />
          <View style={s.grid}>
            <KpiCard variant="hero" wide label={`¿Cuánto vendimos? · ${cur.moneda}`}
              value={fmtMoney(cur.total_cobrado)} detail={`${cur.eventos_cobrados} eventos cobrados`} />
            <KpiCard variant="gold" label="¿Cuánto ganó Daricefy?"
              value={fmtMoney(cur.neto_estimado)} detail="comisión − procesadores" />
            <KpiCard label="¿Cuánto debemos pagar?"
              value={fmtMoney(cur.pendiente_grupos)} detail="retenido a grupos" />
            <KpiCard label="¿Cuánto ya pagamos?" value={fmtMoney(cur.pagado_grupos)} />
            {!compact && (
              <>
                <KpiCard label="Para grupos (total)" value={fmtMoney(cur.dinero_grupos)} />
                <KpiCard label="Comisión procesadores" value={fmtMoney(cur.fees_reales)}
                  detail={cur.fees_no_capturados > 0 ? `${cur.fees_no_capturados} no capturados` : 'todas reales'}
                  detailColor={cur.fees_no_capturados > 0 ? COLORS.orange : COLORS.green} />
                <KpiCard label="Reembolsos" value={fmtMoney(cur.reembolsado)}
                  detail={`${cur.reembolsos} reembolsos`}
                  detailColor={cur.reembolsos > 0 ? COLORS.red : undefined} />
              </>
            )}
          </View>
        </View>
      ))
  );

  const countryCompareBlock = () => (
    (compare?.countries ?? []).length === 0
      ? empty('Sin datos de países todavía.')
      : (compare.countries as any[]).map((c: any) => (
        <View key={c.pais} style={s.countryCard}>
          <View style={s.countryHead}>
            <Text style={s.countryFlag}>{c.pais === 'País no definido' ? '🏳️' : (COUNTRY_FLAGS[c.pais] ?? '🌎')}</Text>
            <Text style={s.countryName}>{c.pais}</Text>
            {c.rating != null && <Text style={s.countryRating}>★ {Number(c.rating).toFixed(1)}</Text>}
          </View>
          <View style={s.countryRow}>
            <View style={s.countryStat}><Text style={s.countryVal}>{c.grupos}</Text><Text style={s.countryLb}>Grupos</Text></View>
            <View style={s.countryStat}><Text style={s.countryVal}>{c.talentos}</Text><Text style={s.countryLb}>Talentos</Text></View>
            <View style={s.countryStat}><Text style={s.countryVal}>{c.eventos}</Text><Text style={s.countryLb}>Eventos</Text></View>
            <View style={[s.countryStat, { flex: 1.6 }]}>
              <Text style={s.countryVal} numberOfLines={1} adjustsFontSizeToFit>
                {fmtMoney(c.ingresos)}
              </Text>
              <Text style={s.countryLb}>Ingresos {c.moneda}</Text>
            </View>
          </View>
        </View>
      ))
  );

  const rankList = (title: string, items: any[], fmt: (v: any) => string, extraLabel?: (x: any) => string) => (
    <View style={s.rankCard}>
      <Text style={s.rankTitle}>{title}</Text>
      {(!items || items.length === 0)
        ? <Text style={s.emptyHint}>Sin datos en este rango.</Text>
        : items.map((it: any, i: number) => (
          <View key={i} style={s.rankRow}>
            <Text style={s.rankNum}>{i + 1}</Text>
            <View style={{ flex: 1, minWidth: 0 }}>
              <Text style={s.rankName} numberOfLines={1}>{it.name}</Text>
              {!!it.state && <Text style={s.rankSub}>{it.state}</Text>}
              {extraLabel && <Text style={s.rankSub}>{extraLabel(it)}</Text>}
            </View>
            <Text style={s.rankVal}>{fmt(it.value)}</Text>
          </View>
        ))}
    </View>
  );

  const alertRow = (count: number, icon: string, label: string, sub: string, screen?: string, onPress?: () => void) => {
    if (!count || count <= 0) return null;
    return (
      <Pressable key={label} onPress={onPress ?? (screen ? () => navigation.navigate(screen) : undefined)}>
        <MetricRow icon={icon} label={label} sub={sub} value={String(count)}
          pill={{ kind: 'bad', label: 'atender' }} />
      </Pressable>
    );
  };

  const alertsBlock = () => {
    if (!alerts) return empty('Cargando alertas…');
    const rows = [
      alertRow(alerts.retiros_pendientes, '💸', 'Retiros pendientes', 'grupos esperando su pago', 'AdminFinancial'),
      alertRow(alerts.pagos_retenidos_viejos, '⏳', 'Pagos retenidos +3 días', 'eventos completados sin liberar', 'AdminFinancial'),
      alertRow(alerts.disputas_abiertas, '⚖️', 'Disputas abiertas', 'requieren resolución', 'AdminDisputes'),
      alertRow(alerts.reembolsos_pendientes, '↩️', 'Reembolsos pendientes', 'transferencias manuales por enviar', 'AdminFinancial'),
      alertRow(alerts.eventos_sin_cerrar, '🕐', 'Eventos sin cerrar', 'en curso con fecha pasada', 'AdminTicketSearch'),
      alertRow(alerts.grupos_suspendidos, '🚫', 'Grupos suspendidos', 'revisar o reactivar', 'AdminGroups'),
      alertRow(alerts.sin_pais, '🏳️', 'Registros sin país', 'clasifícalos uno por uno', undefined, openPending),
      alertRow(alerts.fees_no_capturados, '🧾', 'Fees no capturados', 'cobros sin comisión de procesador registrada', 'AdminFinancial'),
    ].filter(Boolean);
    return rows.length > 0
      ? <>{rows}</>
      : (
        <View style={s.allGoodBox}>
          <Text style={s.allGoodTx}>✅ Todo en orden</Text>
          <Text style={s.emptyHint}>No hay nada que requiera tu atención ahora.</Text>
        </View>
      );
  };

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

      {/* 📑 Pestañas (registro escalable) */}
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={s.tabBar}
        contentContainerStyle={s.tabBarContent}>
        {TAB_REGISTRY.map(t => (
          <Pressable key={t.key} style={[s.tabBtn, tab === t.key && s.tabBtnOn]} onPress={() => setTab(t.key)}>
            <Text style={[s.tabTx, tab === t.key && s.tabTxOn]}>
              {t.label}{t.key === 'alertas' && alertCount > 0 ? ` (${alertCount})` : ''}
            </Text>
          </Pressable>
        ))}
      </ScrollView>

      {loading ? (
        <View style={s.center}><ActivityIndicator size="large" color={COLORS.green} /></View>
      ) : (
        <ScrollView
          contentContainerStyle={s.scroll}
          showsVerticalScrollIndicator={false}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {/* ── Filtros (afectan a TODO, incluido Exportar) ── */}
          <CountryTabs value={country} onChange={co => { setCountry(co); setStateFil(null); }} />
          <StatePicker country={country} value={stateFil} onChange={setStateFil} />
          <View style={s.rangeRow}>
            {RANGES.map(r => (
              <Pressable key={r.key} style={[s.rangeChip, range === r.key && s.rangeChipOn]}
                onPress={() => setRange(r.key)}>
                <Text style={[s.rangeTx, range === r.key && s.rangeTxOn]}>{r.label}</Text>
              </Pressable>
            ))}
          </View>

          {/* ══ RESUMEN — entender el negocio en segundos ══ */}
          {tab === 'resumen' && (
            <>
              {/* ⚠️ ¿Hay algo que requiera atención? */}
              {alertCount > 0 && (
                <Pressable style={s.alertBand} onPress={() => setTab('alertas')}>
                  <Text style={s.alertBandTx}>
                    🚨 {alertCount} tema{alertCount > 1 ? 's' : ''} requiere{alertCount > 1 ? 'n' : ''} tu atención — ver Alertas →
                  </Text>
                </Pressable>
              )}
              {pendTotal > 0 && (
                <Pressable style={s.pendBand} onPress={openPending}>
                  <Text style={s.pendBandTx}>
                    🏳️ {pendTotal} registro{pendTotal > 1 ? 's' : ''} pendiente{pendTotal > 1 ? 's' : ''} de clasificar por país — corregir →
                  </Text>
                </Pressable>
              )}
              {moneyBlock(true)}
              <SectionHeader title="🌎 ¿Cómo va cada país?" note="nunca se mezclan" />
              {countryCompareBlock()}
              {trendData.length > 1 && (
                <>
                  <SectionHeader title="📈 Tendencia" note={`ingreso bruto · ${trendCurrency}`} />
                  <TrendBars title="Últimos 6 meses" right={trendCurrency} data={trendData} />
                </>
              )}
            </>
          )}

          {/* ══ FINANZAS — desglose completo ══ */}
          {tab === 'finanzas' && moneyBlock(false)}

          {/* ══ EVENTOS ══ */}
          {tab === 'eventos' && (
            <>
              <SectionHeader title="🗓 Eventos" />
              <MetricRow icon="🗓" label="Total de eventos" sub="reservas creadas en el rango" value={String(ev.total ?? 0)} />
              <MetricRow icon="✅" label="Completados" value={String(ev.completados ?? 0)}
                pill={ev.total > 0 ? { kind: 'ok', label: `${Math.round(((ev.completados ?? 0) / ev.total) * 100)}%` } : undefined} />
              <MetricRow icon="⏳" label="Próximos" sub="aceptados con fecha por venir" value={String(ev.proximos ?? 0)} />
              <MetricRow icon="🚫" label="Cancelaciones"
                sub={`${ev.cancel_cliente ?? 0} del cliente · ${ev.cancel_grupo ?? 0} del grupo`}
                value={String(ev.cancelados ?? 0)}
                pill={{ kind: cancelRate > 10 ? 'bad' : cancelRate > 5 ? 'warn' : 'ok', label: `${cancelRate}%` }} />
              <MetricRow icon="👻" label="No-shows" value={String(ev.no_shows ?? 0)}
                pill={(ev.no_shows ?? 0) > 0 ? { kind: 'bad', label: 'strikes' } : { kind: 'ok', label: 'limpio' }} />
              <MetricRow icon="↩️" label="Reembolsados" value={String(ev.reembolsados ?? 0)} />
              {trendData.length > 1 && (
                <>
                  <SectionHeader title="📈 Tendencia mensual" note={`ingreso bruto · ${trendCurrency}`} />
                  <TrendBars title="Últimos 6 meses" right={trendCurrency} data={trendData} />
                </>
              )}
            </>
          )}

          {/* ══ PAÍSES — comparativa + pendientes ══ */}
          {tab === 'paises' && (
            <>
              <Pressable style={[s.pendBand, pendTotal === 0 && { borderColor: COLORS.border }]} onPress={openPending}>
                <Text style={s.pendBandTx}>
                  🏳️ Registros pendientes de clasificar: {pendTotal} — {pendTotal > 0 ? 'corregir →' : 'todo clasificado ✅'}
                </Text>
              </Pressable>
              <SectionHeader title="🌎 Comparativa de mercados" note="por país — sin mezclar" />
              {countryCompareBlock()}
              <SectionHeader title="👥 Detalle" />
              {(com.grupos ?? []).map((g: any) => (
                <MetricRow key={`g-${g.pais}`} icon={COUNTRY_FLAGS[g.pais] ?? '🏳️'}
                  label={`Grupos activos · ${g.pais}`}
                  sub={g.nuevos > 0 ? `+${g.nuevos} nuevos en el rango` : 'sin nuevos en el rango'}
                  value={String(g.activos)} />
              ))}
              {(com.talentos ?? []).map((t: any) => (
                <MetricRow key={`t-${t.pais}`} icon="🎤" label={`Talentos · ${t.pais}`}
                  sub={t.nuevos > 0 ? `+${t.nuevos} nuevos en el rango` : undefined}
                  value={String(t.activos)} />
              ))}
              <MetricRow icon="🆕" label="Nuevos registros" sub="clientes + grupos + talentos"
                value={String(com.nuevos_registros ?? 0)} />
            </>
          )}

          {/* ══ RANKINGS ══ */}
          {tab === 'rankings' && (
            <>
              <SectionHeader title="🏆 Grupos" />
              {rankList('Más eventos completados', rankings?.groups_events, v => String(v))}
              {rankList('Más ingresos (su ganancia)', rankings?.groups_income, v => fmtMoney(v))}
              {rankList('Mejor calificación', rankings?.groups_rating, v => `★ ${Number(v).toFixed(1)}`,
                x => `${x.extra} reseñas`)}
              {rankList('Mayor crecimiento (vs periodo anterior)', rankings?.groups_growth,
                v => String(v), x => `antes: ${x.extra}`)}
              <SectionHeader title="🎤 Talentos" />
              {rankList('Más contratados', rankings?.talents_hired, v => String(v))}
              {rankList('Mejor calificación', rankings?.talents_rating, v => `★ ${Number(v).toFixed(1)}`,
                x => `${x.extra} reseñas`)}
              {rankList('Más eventos realizados', rankings?.talents_events, v => String(v))}
              <SectionHeader title="🏙 Ciudades" />
              {rankList('Más eventos', rankings?.cities_events, v => String(v))}
              {rankList('Más ingresos', rankings?.cities_income, v => fmtMoney(v))}
              {rankList('Mayor crecimiento', rankings?.cities_growth, v => String(v), x => `antes: ${x.extra}`)}
            </>
          )}

          {/* ══ ALERTAS — solo lo que requiere atención ══ */}
          {tab === 'alertas' && (
            <>
              <SectionHeader title="🚨 Requieren tu atención" note="toca para ir a resolver" />
              {alertsBlock()}
            </>
          )}

          <View style={{ height: 40 }} />
        </ScrollView>
      )}

      {/* 🏳️ Modal: pendientes de clasificar */}
      <Modal visible={pendOpen} transparent animationType="slide" onRequestClose={() => setPendOpen(false)}>
        <Pressable style={s.modalBackdrop} onPress={() => setPendOpen(false)} />
        <View style={s.modalSheet}>
          <Text style={s.modalTitle}>🏳️ Pendientes de clasificar ({pendItems.length})</Text>
          <Text style={s.emptyHint}>Toca uno para asignarle su país. Nunca se asigna solo.</Text>
          <ScrollView style={{ maxHeight: 420, marginTop: 10 }}>
            {pendItems.length === 0 && (
              <Text style={[s.allGoodTx, { textAlign: 'center', paddingVertical: 20 }]}>✅ Todo clasificado</Text>
            )}
            {pendItems.map(item => (
              <Pressable key={`${item.entity}-${item.id}`} style={s.pendRow} onPress={() => assignCountry(item)}>
                <Text style={{ fontSize: 15 }}>{item.entity === 'group' ? '🎸' : '🎤'}</Text>
                <View style={{ flex: 1 }}>
                  <Text style={s.rankName} numberOfLines={1}>{item.name ?? 'Sin nombre'}</Text>
                  <Text style={s.rankSub}>
                    {item.entity === 'group' ? 'Grupo' : 'Talento'}
                    {item.state ? ` · ${item.state}` : ''}{item.city ? ` · ${item.city}` : ''}
                  </Text>
                </View>
                <Text style={s.pendAssign}>Asignar →</Text>
              </Pressable>
            ))}
          </ScrollView>
        </View>
      </Modal>
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

  // Pestañas (flexGrow:0 + altura fija — nunca se colapsan)
  tabBar: { borderBottomWidth: 1, borderBottomColor: COLORS.border, flexGrow: 0, height: 44 },
  tabBarContent: { paddingHorizontal: SPACING.md, gap: 4, alignItems: 'center' },
  tabBtn: { paddingHorizontal: 13, paddingVertical: 12 },
  tabBtnOn: { borderBottomWidth: 2, borderBottomColor: COLORS.green },
  tabTx: { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.muted2 },
  tabTxOn: { color: COLORS.green, fontFamily: FONTS.bodySemiBold },

  rangeRow: { flexDirection: 'row', gap: 7, marginTop: 9, marginBottom: 4 },
  rangeChip: {
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card, paddingHorizontal: 11, paddingVertical: 6,
  },
  rangeChipOn: { borderColor: 'rgba(0,230,118,0.5)', backgroundColor: COLORS.greenMuted },
  rangeTx: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },
  rangeTxOn: { color: COLORS.green },

  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: 9 },

  // Bandas de alerta / pendientes
  alertBand: {
    marginTop: 10, padding: 12, borderRadius: RADIUS.lg,
    backgroundColor: 'rgba(239,83,80,0.10)', borderWidth: 1, borderColor: 'rgba(239,83,80,0.45)',
  },
  alertBandTx: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.red },
  pendBand: {
    marginTop: 10, padding: 12, borderRadius: RADIUS.lg,
    backgroundColor: 'rgba(255,193,7,0.08)', borderWidth: 1, borderColor: 'rgba(255,193,7,0.4)',
  },
  pendBandTx: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: '#FFC107' },

  // Comparativa de países
  countryCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 13, marginBottom: 9,
  },
  countryHead: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 10 },
  countryFlag: { fontSize: 16 },
  countryName: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, flex: 1 },
  countryRating: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.gold },
  countryRow: { flexDirection: 'row', gap: 8 },
  countryStat: { flex: 1, alignItems: 'center', gap: 2 },
  countryVal: {
    fontFamily: FONTS.title, fontSize: 16, lineHeight: 21, color: COLORS.text,
    fontVariant: ['tabular-nums'], includeFontPadding: false,
  },
  countryLb: { fontFamily: FONTS.body, fontSize: 9.5, color: COLORS.muted },

  // Rankings
  rankCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 13, marginBottom: 9,
  },
  rankTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.text, marginBottom: 8 },
  rankRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 5 },
  rankNum: { fontFamily: FONTS.title, fontSize: 13, color: COLORS.green, width: 18, textAlign: 'center' },
  rankName: { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.text },
  rankSub: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted },
  rankVal: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, fontVariant: ['tabular-nums'] },

  // Vacíos / todo bien
  emptyBox: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 26, alignItems: 'center', marginTop: SPACING.lg, gap: 4,
  },
  emptyTx: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  emptyHint: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted },
  allGoodBox: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    padding: 26, alignItems: 'center', gap: 4,
  },
  allGoodTx: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },

  // Modal pendientes
  modalBackdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)' },
  modalSheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.lg, borderWidth: 1, borderColor: COLORS.border,
  },
  modalTitle: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, marginBottom: 4 },
  pendRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  pendAssign: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
});
