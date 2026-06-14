import { ArrowLeft, BellOff, CheckCheck } from 'lucide-react-native';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  Easing,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';

interface Notification {
  id: string;
  user_id: string;
  type: 'reservation' | 'payment' | 'review' | 'verification' | 'system' |
        'booking_received' | 'booking_accepted' | 'booking_confirmed' |
        'booking_rejected' | 'booking_auto_cancelled' |
        'booking_expired_no_payment' | 'deposit_received' | 'payment_received' |
        'event_completed' | 'event_reminder_24h' | 'payment_released' |
        'job_invitation' |
        'new_quote_request' | 'quote_received' | 'quote_accepted' | 'quote_cancelled' | 'chat' |
        'booking' |
        // Marketing (grupos)
        'ad_space_available' | 'high_demand' | 'no_ads_in_city' | 'first_ad_reminder' |
        // Re-engagement (clientes)
        'new_city_groups' | 'group_nearby' |
        // Otros
        'financial' | 'admin_alert' | 'dispute_opened' | 'dispute_received' |
        'event_started' | 'booking_cancelled' |
        // Competencia de bids
        'bid_displaced' | 'bid_expiring_soon' | 'bid_expiry_reminder' |
        // Anuncios
        'ad_approved' | 'ad_rejected' | 'ad_payment_confirmed' | 'ad_expiring_soon' | 'ad_expired' |
        // Zona / demanda express
        'zone_demand' |
        // Admin / pagos / KYC
        'payout' | 'wallet' | 'fraud_alert' |
        // Cotización enviada a integrantes del grupo (dueño mandó precio al cliente)
        'quote_sent_to_client' |
        // Proximidad al evento
        'request_expired_proximity' | 'quote_expired_proximity' |
        // Horas extra
        'extra_hour_proposed' | 'extra_hour_approved_by_client' | 'extra_hour_payment_confirmed';
  title: string;
  message?: string;
  body?: string;
  data?: Record<string, unknown>;
  reference_id: string | null;
  is_read: boolean;
  created_at: string;
}

const TYPE_ICONS: Record<string, string> = {
  reservation: '🎉',
  booking_received: '🎉',
  booking_accepted: '✅',
  booking_confirmed: '🎉',
  booking_rejected: '❌',
  booking_auto_cancelled: '⏰',
  booking_expired_no_payment: '⏰',
  deposit_received: '💰',
  payment_received: '💰',
  event_completed: '🎵',
  event_reminder_24h: '🔔',
  payment_released: '💰',
  payment: '💰',
  review: '⭐',
  verification: '✅',
  system: '🔔',
  job_invitation:   '🎵',
  new_quote_request: '📋',
  quote_received:    '📋',
  quote_accepted:    '✅',
  quote_cancelled:   '❌',
  chat:              '💬',
  booking:           '⚡',
  // Proximidad al evento
  request_expired_proximity: '⏱',
  quote_expired_proximity:   '⏱',
  // Marketing
  ad_space_available: '🔥',
  high_demand:        '⚡',
  no_ads_in_city:     '🚀',
  first_ad_reminder:  '📢',
  // Re-engagement
  new_city_groups:    '🎶',
  group_nearby:       '📍',
  // Competencia
  bid_displaced:      '📉',
  bid_expiring_soon:  '⚠️',
  bid_expiry_reminder:'⏰',
  // Anuncios
  ad_approved:        '⭐',
  ad_rejected:        '❌',
  ad_payment_confirmed:'💰',
  ad_expiring_soon:   '⚠️',
  ad_expired:         '❌',
  // Zona / demanda express
  zone_demand:        '📍',
  // Otros
  financial:          '💳',
  admin_alert:        '🚨',
  dispute_opened:     '⚖️',
  dispute_received:   '⚖️',
  event_started:      '🎤',
  booking_cancelled:  '❌',
  // Horas extra
  extra_hour_proposed:           '⏰',
  extra_hour_approved_by_client: '✅',
  extra_hour_payment_confirmed:  '💳',
};

export default function NotificationsScreen({ navigation }: any) {
  const [notifications, setNotifications] = useState<Notification[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [role, setRole] = useState<string | null>(null);

  useEffect(() => {
    fetchNotifications();
  }, []);

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchNotifications();
    setRefreshing(false);
  };

  const fetchNotifications = async () => {
    setLoading(true);
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) {
      setLoading(false);
      return;
    }

    // Obtener rol del usuario
    const { data: profile } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', sessionData.session.user.id)
      .single();
    setRole(profile?.role ?? null);

    // Obtener notificaciones
    const { data, error } = await supabase
      .from('notifications')
      .select('*')
      .eq('user_id', sessionData.session.user.id)
      .order('created_at', { ascending: false })
      .limit(50);

    if (data) setNotifications(data);
    setLoading(false);
  };

  const markAsRead = async (notif: Notification) => {
    if (notif.is_read) {
      // Ya está leída, solo navegar
      handleNavigation(notif);
      return;
    }

    // Marcar como leída en la BD
    await supabase
      .from('notifications')
      .update({ is_read: true })
      .eq('id', notif.id);

    // Actualizar estado local
    setNotifications(prev =>
      prev.map(n => (n.id === notif.id ? { ...n, is_read: true } : n))
    );

    // Navegar
    handleNavigation(notif);
  };

  const handleNavigation = async (notif: Notification) => {
    // Reservation ID can come from old reference_id or new data.reservation_id (JSONB)
    const reservationId =
      notif.reference_id ??
      (notif.data?.reservation_id as string | undefined) ??
      null;

    const goToReservation = async (asGroup: boolean) => {
      if (reservationId) {
        const { data: reservation } = await supabase
          .from('reservations')
          .select('*, client:profiles(full_name, phone), group:groups(id, name, genre, city, profile_image, owner_id), package:packages(name, duration_hours)')
          .eq('id', reservationId)
          .single();

        if (reservation) {
          if (role === 'talent') {
            // Integrante: ver detalle en modo lectura para confirmar asistencia
            navigation.navigate('GroupReservationDetail', { reservation, readOnly: true });
          } else if (asGroup) {
            navigation.navigate('GroupConfirmBooking', { reservation });
          } else {
            // Cliente: ir a la lista de reservas
            navigation.navigate('ClientReservations');
          }
          return;
        }
      }
      // Fallback to list
      if (role === 'talent') {
        // No hacer nada extra, el usuario ya está en la app
      } else if (asGroup) {
        navigation.navigate('GroupReservations');
      } else {
        navigation.navigate('ClientReservations');
      }
    };

    switch (notif.type) {
      // ── Legacy type ────────────────────────────────────────────────────────
      case 'reservation':
        await goToReservation(role === 'group');
        break;

      // ── New booking flow types ─────────────────────────────────────────────
      case 'booking_received':
        // Group received a new booking request
        await goToReservation(true);
        break;

      case 'booking_accepted':
        // Client received payment prompt
        await goToReservation(false);
        break;

      case 'booking_confirmed':
      case 'booking_rejected':
      case 'booking_auto_cancelled':
      case 'booking_expired_no_payment':
      case 'event_completed':
        // Client-facing: open reservation detail
        await goToReservation(role === 'group');
        break;

      case 'deposit_received':
      case 'payment_received':
      case 'event_reminder_24h':
        await goToReservation(role === 'group');
        break;

      case 'payment_released':
        if (role === 'group') {
          navigation.navigate('GroupEarnings');
        } else {
          await goToReservation(false);
        }
        break;

      // ── Other types ────────────────────────────────────────────────────────
      case 'payment':
        if (role === 'group') {
          navigation.navigate('GroupEarnings');
        }
        break;

      case 'review':
        if (role === 'group') {
          navigation.navigate('GroupReservations');
        }
        break;

      case 'verification':
        if (role === 'admin') {
          navigation.navigate('AdminVerifications');
        } else if (role === 'group') {
          navigation.navigate('GroupVerification');
        }
        break;

      case 'job_invitation':
        if (role === 'talent') {
          // Bolsa is a tab inside TalentHome, not a root stack screen
          navigation.navigate('TalentHome', { screen: 'Bolsa' });
        } else if (role === 'group') {
          navigation.navigate('GroupSentInvitations');
        }
        break;

      // ── Cotizaciones ───────────────────────────────────────────────────────
      case 'new_quote_request': {
        // Dueño o integrante: ir directo al detalle si tenemos quote_id
        const qId = notif.data?.quote_id as string | undefined;
        if (qId) {
          // Obtener el quote para pasarlo como param
          const { data: qData } = await supabase
            .from('quotes')
            .select('*, client:profiles!client_id(full_name, avatar_url)')
            .eq('id', qId)
            .single();
          if (qData) {
            navigation.navigate('GroupQuoteDetail', { quote: qData });
          } else {
            navigation.navigate('GroupQuotes');
          }
        } else {
          navigation.navigate('GroupQuotes');
        }
        break;
      }

      case 'quote_sent_to_client': {
        // Integrante del grupo: el dueño envió el precio al cliente — ver detalle
        const qStcId = notif.data?.quote_id as string | undefined;
        if (qStcId) {
          const { data: qData } = await supabase
            .from('quotes')
            .select('*, client:profiles!client_id(full_name, avatar_url)')
            .eq('id', qStcId)
            .single();
          if (qData) {
            navigation.navigate('GroupQuoteDetail', { quote: qData });
          } else {
            navigation.navigate('GroupQuotes');
          }
        } else {
          navigation.navigate('GroupQuotes');
        }
        break;
      }

      case 'quote_received': {
        // Cliente: ir a ver la cotización recibida
        const quoteId = notif.data?.quote_id as string | undefined;
        if (quoteId) {
          navigation.navigate('ClientQuoteDetail', { quoteId });
        } else {
          navigation.navigate('ClientReservations');
        }
        break;
      }

      case 'quote_accepted':
      case 'quote_cancelled': {
        // Grupo/integrante: ir al detalle de la cotización
        const qaId = notif.data?.quote_id as string | undefined;
        if (qaId) {
          const { data: qData } = await supabase
            .from('quotes')
            .select('*, client:profiles!client_id(full_name, avatar_url)')
            .eq('id', qaId)
            .single();
          if (qData) {
            navigation.navigate('GroupQuoteDetail', { quote: qData });
          } else {
            navigation.navigate('GroupQuotes');
          }
        } else {
          navigation.navigate('GroupQuotes');
        }
        break;
      }

      case 'booking': {
        if (role === 'talent') {
          // Eventos tab inside TalentHome, not a root stack screen
          navigation.navigate('TalentHome', { screen: 'Eventos' });
        } else if (role === 'group') {
          // Grupo (dueño): nueva solicitud express disponible
          navigation.navigate('OpenRequests');
        } else {
          // Cliente: propuesta recibida → ir directo a Mis solicitudes
          navigation.navigate('OpenRequest', { tab: 'mine' });
        }
        break;
      }

      // ── Marketing (grupos) ─────────────────────────────────────────────────
      case 'ad_space_available':
      case 'high_demand':
      case 'no_ads_in_city':
      case 'first_ad_reminder':
        navigation.navigate('AdvertisingPackages');
        break;

      // ── Re-engagement (clientes) ───────────────────────────────────────────
      case 'new_city_groups':
      case 'group_nearby':
        // Lleva al explorador de grupos
        navigation.navigate('Explorar');
        break;

      case 'bid_displaced':
      case 'bid_expiring_soon':
      case 'bid_expiry_reminder':
        navigation.navigate('Bidding');
        break;

      // ── Zona / demanda express ─────────────────────────────────────────────
      case 'zone_demand': {
        const reqId = notif.data?.event_request_id as string | undefined;
        navigation.navigate('OpenRequests', reqId ? { requestId: reqId } : undefined);
        break;
      }

      // ── Anuncios ───────────────────────────────────────────────────────────
      case 'ad_payment_confirmed':
      case 'ad_approved':
      case 'ad_expiring_soon':
      case 'ad_expired':
        navigation.navigate('AdvertisingPackages');
        break;

      // ── Disputas / operativo ──────────────────────────────────────────────
      case 'dispute_opened':
      case 'dispute_received':
        if (role === 'admin') {
          navigation.navigate('AdminDisputes');
        } else {
          await goToReservation(role === 'group');
        }
        break;

      case 'event_started':
        await goToReservation(role === 'group');
        break;

      case 'booking_cancelled':
        await goToReservation(role === 'group');
        break;

      // ── Admin: retiros ────────────────────────────────────────────────────
      case 'payout':
      case 'wallet':
        if (role === 'admin') {
          navigation.navigate('AdminWithdrawals');
        } else if (role === 'group') {
          navigation.navigate('Wallet');
        }
        break;

      // ── Admin: fraude — sin pantalla dedicada, usa AdminDisputes como proxy
      case 'fraud_alert':
        if (role === 'admin') {
          navigation.navigate('AdminDisputes');
        }
        break;

      // ── Proximidad al evento ────────────────────────────────────────────────
      case 'request_expired_proximity':
        // Al cliente: lleva al flujo Express (Solicitar grupo ahora)
        if (role === 'client') {
          navigation.navigate('OpenRequest' as any);
        }
        break;

      case 'quote_expired_proximity':
        // Al grupo: lleva a sus reservas
        if (role === 'group') {
          navigation.navigate('GroupReservations');
        }
        break;

      // ── Horas extra ──────────────────────────────────────────────────────────
      case 'extra_hour_proposed':
        // Al cliente: lleva a la pantalla de aprobación de hora extra
        if (role === 'client') {
          navigation.navigate('ClientExtraHours' as any, {
            reservation_id: notif.data?.reservation_id,
          });
        }
        break;

      case 'extra_hour_approved_by_client':
        // Al grupo: lleva al EventTimer para confirmar continuación
        if (role === 'group') {
          navigation.navigate('EventTimer' as any, {
            reservation_id: notif.data?.reservation_id,
          });
        }
        break;

      case 'extra_hour_payment_confirmed':
        // Al cliente: lleva a ClientExtraHours para ver detalle del cobro
        if (role === 'client') {
          navigation.navigate('ClientExtraHours' as any, {
            reservation_id: notif.data?.reservation_id,
          });
        }
        break;

      case 'system': {
        // Nombres de pantalla legacy usados en SQL → nombres reales del navegador.
        // 'Dashboard'  → pantalla principal del rol actual
        // 'Home'/'Explore' → explorador (clientes) o dashboard (grupos)
        const SCREEN_REMAP: Record<string, string> = {
          Dashboard:      role === 'group' ? 'GroupHome' : role === 'admin' ? 'AdminHome' : 'Explorar',
          Home:           role === 'group' ? 'GroupHome' : 'Explorar',
          Explore:        'Explorar',
          AdminDashboard: 'AdminHome',
        };
        const rawSysScreen = notif.data?.screen as string | undefined;
        const sysScreen = rawSysScreen
          ? (SCREEN_REMAP[rawSysScreen] ?? rawSysScreen)
          : undefined;
        if (sysScreen) {
          try { navigation.navigate(sysScreen as any); } catch { /* pantalla inválida */ }
        }
        break;
      }

      default: {
        // Fallback genérico: si la notificación tiene data.screen, navegar ahí
        const screen = notif.data?.screen as string | undefined;
        if (screen) {
          try { navigation.navigate(screen as any); } catch { /* pantalla inválida */ }
        }
        break;
      }
    }
  };

  const markAllAsRead = async () => {
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) return;

    await supabase
      .from('notifications')
      .update({ is_read: true })
      .eq('user_id', sessionData.session.user.id)
      .eq('is_read', false);

    setNotifications(prev => prev.map(n => ({ ...n, is_read: true })));
  };

  const unreadCount = notifications.filter(n => !n.is_read).length;

  if (loading) {
    return (
      <View style={styles.container}>
        <Particles />
        <View style={styles.center}>
          <ActivityIndicator size="large" color={COLORS.green} />
        </View>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>Notificaciones</Text>
          {unreadCount > 0 ? (
            <Pressable style={styles.markAllBtn} onPress={markAllAsRead}>
              <CheckCheck size={16} color={COLORS.green} />
            </Pressable>
          ) : (
            <View style={{ width: 40 }} />
          )}
        </View>

        {notifications.length === 0 ? (
          <View style={styles.empty}>
            <BellOff size={52} color={COLORS.muted} strokeWidth={1.5} />
            <Text style={styles.emptyTitle}>Sin notificaciones</Text>
            <Text style={styles.emptyText}>
              Aquí aparecerán tus reservas, pagos y novedades.
            </Text>
          </View>
        ) : (
          <ScrollView
            showsVerticalScrollIndicator={false}
            contentContainerStyle={styles.list}
            refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
          >
            {notifications.map((notif, index) => (
              <NotificationCard
                key={notif.id}
                notif={notif}
                index={index}
                onPress={() => markAsRead(notif)}
              />
            ))}
          </ScrollView>
        )}
      </SafeAreaView>
    </View>
  );
}

// ── Componente de tarjeta individual ──────────────────────────────────────────

const MARKETING_TYPES = new Set([
  'ad_space_available', 'high_demand', 'no_ads_in_city', 'first_ad_reminder',
  'bid_displaced', 'bid_expiring_soon',
]);
const CLIENT_TYPES = new Set(['new_city_groups', 'group_nearby']);

const MARKETING_CTA: Record<string, string> = {
  ad_space_available: 'Ver espacios →',
  high_demand:        'Promocionarme ahora →',
  no_ads_in_city:     'Ser el primero →',
  first_ad_reminder:  'Ver paquetes →',
  bid_displaced:      'Recuperar posición →',
  bid_expiring_soon:  'Renovar ahora →',
  new_city_groups:    'Ver grupos →',
  group_nearby:       'Explorar →',
};

function NotificationCard({
  notif,
  index,
  onPress,
}: {
  notif: Notification;
  index: number;
  onPress: () => void;
}) {
  const fadeAnim = useRef(new Animated.Value(0)).current;
  const slideAnim = useRef(new Animated.Value(20)).current;
  const scaleAnim = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    Animated.parallel([
      Animated.timing(fadeAnim, {
        toValue: 1,
        duration: 400,
        delay: index * 60,
        useNativeDriver: true,
      }),
      Animated.timing(slideAnim, {
        toValue: 0,
        duration: 400,
        delay: index * 60,
        easing: Easing.out(Easing.ease),
        useNativeDriver: true,
      }),
    ]).start();
  }, []);

  const handlePressIn = () => {
    Animated.spring(scaleAnim, {
      toValue: 0.97,
      useNativeDriver: true,
    }).start();
  };

  const handlePressOut = () => {
    Animated.spring(scaleAnim, {
      toValue: 1,
      friction: 5,
      useNativeDriver: true,
    }).start();
  };

  const icon = TYPE_ICONS[notif.type] ?? '🔔';
  const timeAgo = getTimeAgo(notif.created_at);

  return (
    <Animated.View
      style={{
        opacity: fadeAnim,
        transform: [{ translateY: slideAnim }, { scale: scaleAnim }],
      }}
    >
      <Pressable
        style={[styles.card, !notif.is_read && styles.cardUnread]}
        onPress={onPress}
        onPressIn={handlePressIn}
        onPressOut={handlePressOut}
      >
        {!notif.is_read && <View style={styles.unreadDot} />}

        <View style={styles.iconWrapper}>
          <Text style={styles.icon}>{icon}</Text>
        </View>

        <View style={styles.content}>
          <Text style={styles.title}>{notif.title}</Text>
          <Text style={styles.body} numberOfLines={2}>
            {notif.body || notif.message}
          </Text>
          <View style={styles.cardFooter}>
            <Text style={styles.time}>{timeAgo}</Text>
            {(MARKETING_TYPES.has(notif.type) || CLIENT_TYPES.has(notif.type)) && (
              <Pressable style={styles.ctaBtn} onPress={onPress}>
                <Text style={styles.ctaBtnText}>
                  {MARKETING_CTA[notif.type] ?? 'Ver →'}
                </Text>
              </Pressable>
            )}
          </View>
        </View>
      </Pressable>
    </Animated.View>
  );
}

// ── Helper: tiempo relativo ───────────────────────────────────────────────────

function getTimeAgo(timestamp: string): string {
  const now = new Date();
  const past = new Date(timestamp);
  const diffMs = now.getTime() - past.getTime();
  const diffMins = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMs / 3600000);
  const diffDays = Math.floor(diffMs / 86400000);

  if (diffMins < 1) return 'Ahora';
  if (diffMins < 60) return `Hace ${diffMins} min`;
  if (diffHours < 24) return `Hace ${diffHours}h`;
  if (diffDays === 1) return 'Ayer';
  if (diffDays < 7) return `Hace ${diffDays} días`;

  // Más de 7 días: mostrar fecha
  const day = past.getDate();
  const month = past.toLocaleString('es-MX', { month: 'short' });
  return `${day} ${month}`;
}

// ── Estilos ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl,
    paddingVertical: 14,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40,
    height: 40,
    borderRadius: 12,
    backgroundColor: COLORS.card,
    borderWidth: 1,
    borderColor: COLORS.border,
    alignItems: 'center',
    justifyContent: 'center',
  },
  headerTitle: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 16,
    color: COLORS.text,
  },
  markAllBtn: {
    width: 40,
    height: 40,
    borderRadius: 12,
    backgroundColor: COLORS.greenMuted,
    borderWidth: 1,
    borderColor: COLORS.green,
    alignItems: 'center',
    justifyContent: 'center',
  },
  list: { padding: SPACING.xl, gap: 10, paddingBottom: 32 },
  card: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 14,
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
    padding: SPACING.lg,
    position: 'relative',
  },
  cardUnread: {
    borderColor: COLORS.greenGlow,
    backgroundColor: 'rgba(0,230,118,0.04)',
  },
  unreadDot: {
    position: 'absolute',
    top: 14,
    right: 14,
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: COLORS.green,
  },
  iconWrapper: {
    width: 44,
    height: 44,
    borderRadius: 14,
    backgroundColor: COLORS.card2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  icon: { fontSize: 22 },
  content: { flex: 1 },
  title: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 15,
    color: COLORS.text,
    marginBottom: 4,
  },
  body: {
    fontFamily: FONTS.body,
    fontSize: 13,
    color: COLORS.muted2,
    lineHeight: 19,
    marginBottom: 8,
  },
  time: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  cardFooter: {
    flexDirection: 'row' as const,
    alignItems: 'center' as const,
    justifyContent: 'space-between' as const,
    marginTop: 2,
  },
  ctaBtn: {
    backgroundColor: COLORS.green,
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
  ctaBtnText: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 11,
    color: COLORS.bg,
  },
  // Empty state
  empty: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 40,
    paddingBottom: 80,
  },
  emptyTitle: {
    fontFamily: FONTS.title,
    fontSize: 20,
    color: COLORS.text,
    marginTop: 20,
    marginBottom: 8,
  },
  emptyText: {
    fontFamily: FONTS.body,
    fontSize: 14,
    color: COLORS.muted2,
    textAlign: 'center',
    lineHeight: 22,
  },
});
