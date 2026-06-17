import { NavigationContainer, useNavigationContainerRef } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import React, { useEffect, useRef, useState } from 'react';
import * as ExpoNotifications from 'expo-notifications';
import * as Location from 'expo-location';
import * as Linking from 'expo-linking';
import {
  Animated,
  Easing,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { Briefcase, Calendar, CalendarDays, Compass, LayoutDashboard, Megaphone, User, Users } from 'lucide-react-native';
import { useTranslation } from 'react-i18next';
import { COLORS, FONTS } from '../src/config/theme';
import { supabase } from '../src/config/supabase';
import { useAuth } from '../src/context/AuthContext';
import { GroupBadgesProvider, useGroupBadges } from '../src/context/GroupBadgesContext';
import { ClientBadgesProvider, useClientBadges } from '../src/context/ClientBadgesContext';
import { usePushNotifications } from '../src/hooks/usePushNotifications';
import Particles from '../src/components/ui/Particles';

// Auth
import IntroScreen    from '../src/screens/auth/IntroScreen';
import LoginScreen    from '../src/screens/auth/LoginScreen';
import RegisterScreen         from '../src/screens/auth/RegisterScreen';
import LocationRequestScreen from '../src/screens/auth/LocationRequestScreen';

// Client
import HomeScreen from '../src/screens/client/HomeScreen';
import GroupDetailScreen from '../src/screens/client/GroupDetailScreen';
import BookingScreen from '../src/screens/client/BookingScreen';
import ClientReservationsScreen from '../src/screens/client/ReservationsScreen';
import LiveEventScreen from '../src/screens/client/LiveEventScreen';

// Talent
import TalentJobBoardScreen from '../src/screens/talent/JobBoardScreen';
import MemberEventsScreen from '../src/screens/talent/MemberEventsScreen';

// Group
import GroupDashboardScreen from '../src/screens/group/DashboardScreen';
import GroupEventsScreen from '../src/screens/group/GroupEventsScreen';
import GroupReservationsScreen from '../src/screens/group/ReservationsScreen';
import GroupConfirmBookingScreen from '../src/screens/group/ConfirmBookingScreen';
import EventTimerScreen from '../src/screens/group/EventTimerScreen';
import GroupVerificationScreen from '../src/screens/group/VerificationScreen';
import ExtraHoursScreen from '../src/screens/group/ExtraHoursScreen';
import GroupEarningsScreen from '../src/screens/group/EarningsScreen';
import GroupCalendarScreen from '../src/screens/group/CalendarScreen';
import GroupAvailabilityScreen from '../src/screens/group/AvailabilityScreen';
import GroupTalentSearchScreen from '../src/screens/group/TalentSearchScreen';
import TalentProfileScreen from '../src/screens/group/TalentProfileScreen';
import GroupSentInvitationsScreen from '../src/screens/group/SentInvitationsScreen';
import GroupJobBoardScreen from '../src/screens/talent/JobBoardScreen';
import GroupBenefitsScreen from '../src/screens/group/BenefitsScreen';
import GroupQuotesScreen from '../src/screens/group/QuotesScreen';
import GroupQuoteDetailScreen from '../src/screens/group/QuoteDetailScreen';
import GroupStatsScreen from '../src/screens/group/StatsScreen';
import QuoteFormScreen from '../src/screens/client/QuoteFormScreen';
import ClientQuoteDetailScreen from '../src/screens/client/ClientQuoteDetailScreen';
import QuotePaymentScreen from '../src/screens/client/QuotePaymentScreen';
import OpenRequestScreen from '../src/screens/client/OpenRequestScreen';
import GuidedRequestScreen from '../src/screens/client/GuidedRequestScreen';
import GroupsMapScreen from '../src/screens/client/GroupsMapScreen';
import GroupOpenRequestsScreen from '../src/screens/group/OpenRequestsScreen';
import GroupProposeRequestScreen from '../src/screens/group/ProposeRequestScreen';
import BiddingScreen              from '../src/screens/group/BiddingScreen';
import RecommendationScreen       from '../src/screens/group/RecommendationScreen';
import PlusScreen                 from '../src/screens/group/PlusScreen';
import IncomingExpressScreen      from '../src/screens/group/IncomingExpressScreen';
import ExpressCarousel            from '../src/components/express/ExpressCarousel';
import { ExpressProvider }        from '../src/context/ExpressContext';

// Talent
import TalentStatsScreen from '../src/screens/talent/StatsScreen';

// Admin
import AdminDashboardScreen from '../src/screens/admin/DashboardScreen';
import AdminMapScreen from '../src/screens/admin/AdminMapScreen';
import AdminVerificationsScreen from '../src/screens/admin/VerificationsScreen';
import AdminDisputesScreen from '../src/screens/admin/DisputesScreen';
import AdminGroupsScreen from '../src/screens/admin/GroupsScreen';
import AdminTalentsScreen from '../src/screens/admin/TalentsScreen';
import AdminPromotionsScreen from '../src/screens/admin/PromotionsScreen';
import AdminStatsScreen from '../src/screens/admin/StatsScreen';
import AdminFinancialScreen from '../src/screens/admin/FinancialScreen';

// Client (extra)
import ClientVerificationScreen from '../src/screens/client/VerificationScreen';
import ClientExtraHoursScreen from '../src/screens/client/ClientExtraHoursScreen';
import CreateAdvertisementScreen      from '../src/screens/client/CreateAdvertisementScreen';
import AdvertisingPackagesScreen      from '../src/screens/client/AdvertisingPackagesScreen';

// Shared — catálogo de promociones (rol-aware)
import PromocionarseScreen from '../src/screens/shared/PromocionarseScreen';

// Shared
import ProfileScreen from '../src/screens/shared/ProfileScreen';
import NotificationsScreen from '../src/screens/shared/NotificationsScreen';
import ChatScreen from '../src/screens/shared/ChatScreen';
import WalletScreen from '../src/screens/shared/WalletScreen';
import WithdrawScreen from '../src/screens/shared/WithdrawScreen';
import EventPayoutsScreen from '../src/screens/shared/EventPayoutsScreen';

// Admin (wallet)
import AdminWithdrawalsScreen from '../src/screens/admin/WithdrawalsScreen';
import AdminMediaReviewScreen from '../src/screens/admin/MediaReviewScreen';
import AdApprovalScreen from '../src/screens/admin/AdApprovalScreen';

const Stack = createNativeStackNavigator();
const Tab   = createBottomTabNavigator();

// ─── Location permission gate ─────────────────────────────────────────────────

type LocStatus = 'checking' | 'granted' | 'denied' | 'blocked';

function LocationGate({ children }: { children: React.ReactNode }) {
  const [status, setStatus] = useState<LocStatus>('checking');
  const fadeAnim = useRef(new Animated.Value(0)).current;

  const check = async () => {
    const { status: s } = await Location.getForegroundPermissionsAsync();
    if (s === 'granted') { setStatus('granted'); return; }
    const { status: asked } = await Location.requestForegroundPermissionsAsync();
    setStatus(asked === 'granted' ? 'granted' : asked === 'denied' ? 'blocked' : 'denied');
  };

  useEffect(() => {
    check();
  }, []);

  useEffect(() => {
    if (status !== 'checking') {
      Animated.timing(fadeAnim, { toValue: 1, duration: 600, useNativeDriver: true }).start();
    }
  }, [status]);

  if (status === 'checking' || status === 'granted') return <>{children}</>;

  return (
    <View style={lgStyles.container}>
      <Animated.View style={[lgStyles.card, { opacity: fadeAnim }]}>
        <View style={lgStyles.iconBox}>
          <Text style={lgStyles.iconEmoji}>📍</Text>
        </View>
        <Text style={lgStyles.title}>Activa tu ubicación</Text>
        <Text style={lgStyles.body}>
          Necesitamos tu ubicación para mostrarte los grupos y talentos de tu estado.
          Sin ella no podremos personalizar tu experiencia.
        </Text>
        {status === 'blocked' ? (
          <>
            <Text style={lgStyles.hint}>
              Ya denegaste el permiso. Ve a{'\n'}
              <Text style={lgStyles.hintBold}>Configuración → Aplicaciones → Permisos → Ubicación</Text>
              {'\n'}y actívala manualmente.
            </Text>
            <Pressable style={lgStyles.btn} onPress={() => Linking.openSettings()}>
              <Text style={lgStyles.btnText}>Abrir Configuración</Text>
            </Pressable>
          </>
        ) : (
          <Pressable style={lgStyles.btn} onPress={check}>
            <Text style={lgStyles.btnText}>Permitir ubicación</Text>
          </Pressable>
        )}
        <Text style={lgStyles.skip} onPress={() => setStatus('granted')}>
          Continuar sin ubicación →
        </Text>
      </Animated.View>
    </View>
  );
}

const lgStyles = StyleSheet.create({
  container: {
    flex: 1, backgroundColor: '#040404',
    alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: 28,
  },
  card: {
    width: '100%', backgroundColor: '#0e0e0e',
    borderRadius: 20, padding: 28,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.18)',
    alignItems: 'center',
  },
  iconBox: {
    width: 68, height: 68, borderRadius: 34,
    backgroundColor: 'rgba(0,230,118,0.12)',
    alignItems: 'center', justifyContent: 'center',
    marginBottom: 18,
  },
  iconEmoji: { fontSize: 32 },
  title: {
    fontFamily: FONTS.title, fontSize: 22,
    color: '#fff', textAlign: 'center', marginBottom: 10,
  },
  body: {
    fontFamily: FONTS.body, fontSize: 14,
    color: 'rgba(255,255,255,0.6)', textAlign: 'center',
    lineHeight: 21, marginBottom: 20,
  },
  hint: {
    fontFamily: FONTS.body, fontSize: 13,
    color: 'rgba(255,255,255,0.5)', textAlign: 'center',
    lineHeight: 20, marginBottom: 20,
  },
  hintBold: { color: 'rgba(255,255,255,0.8)', fontFamily: FONTS.bodySemiBold },
  btn: {
    width: '100%', backgroundColor: '#00E676',
    borderRadius: 14, paddingVertical: 14,
    alignItems: 'center', marginBottom: 14,
  },
  btnText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#040404',
  },
  skip: {
    fontFamily: FONTS.bodyMedium, fontSize: 13,
    color: 'rgba(255,255,255,0.35)',
  },
});

// ─── Splash / Loading screen ──────────────────────────────────────────────────

function PulsingDot({ delay }: { delay: number }) {
  const scale   = useRef(new Animated.Value(0.5)).current;
  const opacity = useRef(new Animated.Value(0.3)).current;

  useEffect(() => {
    Animated.loop(
      Animated.sequence([
        Animated.delay(delay),
        Animated.parallel([
          Animated.timing(scale,   { toValue: 1,   duration: 500, easing: Easing.out(Easing.ease), useNativeDriver: true }),
          Animated.timing(opacity, { toValue: 1,   duration: 500, useNativeDriver: true }),
        ]),
        Animated.parallel([
          Animated.timing(scale,   { toValue: 0.5, duration: 500, easing: Easing.in(Easing.ease), useNativeDriver: true }),
          Animated.timing(opacity, { toValue: 0.3, duration: 500, useNativeDriver: true }),
        ]),
      ])
    ).start();
  }, []);

  return (
    <Animated.View
      style={{
        width: 7, height: 7, borderRadius: 3.5,
        backgroundColor: COLORS.green,
        transform: [{ scale }],
        opacity,
        marginHorizontal: 4,
      }}
    />
  );
}

function SplashLoader() {
  const fadeAnim   = useRef(new Animated.Value(0)).current;
  const scaleAnim  = useRef(new Animated.Value(0.88)).current;
  const rotateAnim = useRef(new Animated.Value(0)).current;
  const pulseAnim  = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    Animated.parallel([
      Animated.timing(fadeAnim,  { toValue: 1, duration: 900, easing: Easing.out(Easing.ease), useNativeDriver: true }),
      Animated.spring(scaleAnim, { toValue: 1, tension: 60, friction: 7, useNativeDriver: true }),
    ]).start();

    Animated.loop(
      Animated.timing(rotateAnim, { toValue: 1, duration: 14000, easing: Easing.linear, useNativeDriver: true })
    ).start();

    Animated.loop(
      Animated.sequence([
        Animated.timing(pulseAnim, { toValue: 1.06, duration: 1800, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
        Animated.timing(pulseAnim, { toValue: 1,    duration: 1800, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
      ])
    ).start();
  }, []);

  const spin = rotateAnim.interpolate({ inputRange: [0, 1], outputRange: ['0deg', '360deg'] });

  return (
    <View style={splash.container}>

      {/* ── Energy vortex background ── */}
      <View style={[StyleSheet.absoluteFillObject, { alignItems: 'center', justifyContent: 'center' }]} pointerEvents="none">
        <View style={splash.glowBlob} />
        <Animated.View style={[splash.ring, { width: 370, height: 370, borderRadius: 185, opacity: 0.10, transform: [{ rotate: spin }] }]} />
        <View           style={[splash.ring, { width: 275, height: 275, borderRadius: 138, opacity: 0.17 }]} />
        <Animated.View style={[splash.ring, { width: 200, height: 200, borderRadius: 100, opacity: 0.23, transform: [{ scale: pulseAnim }] }]} />
        <View           style={[splash.ring, { width: 135, height: 135, borderRadius: 68,  opacity: 0.32 }]} />
        {/* Radial beams */}
        {[25, 70, 115, -25, -70, -115].map((angle, i) => (
          <View key={i} style={[splash.beam, { transform: [{ rotate: `${angle}deg` }] }]} />
        ))}
        {/* Gold/green accent dots on ring perimeter */}
        <View style={[splash.energyDot, { marginTop: -138, backgroundColor: 'rgba(255,215,0,0.85)' }]} />
        <View style={[splash.energyDot, { marginTop:  138, backgroundColor: 'rgba(0,230,118,0.85)' }]} />
        <View style={[splash.energyDot, { marginLeft: -138, backgroundColor: 'rgba(255,215,0,0.6)' }]} />
        <View style={[splash.energyDot, { marginLeft:  138, backgroundColor: 'rgba(0,230,118,0.6)' }]} />
      </View>

      {/* ── DARICEFY logo + taglines ── */}
      <Animated.View style={{ alignItems: 'center', opacity: fadeAnim, transform: [{ scale: scaleAnim }] }}>
        <Text style={splash.logoText} adjustsFontSizeToFit numberOfLines={1}>
          Darice<Text style={splash.logoX}>fy</Text>
        </Text>
        <Text style={splash.tagline}>Conecta talento y eventos</Text>
        <Text style={splash.subtitle}>La plataforma de música en vivo que te lleva más lejos.</Text>
        <View style={splash.dotsRow}>
          <PulsingDot delay={0} />
          <PulsingDot delay={180} />
          <PulsingDot delay={360} />
        </View>
      </Animated.View>

    </View>
  );
}

// ─── Auth error screen (profile failed to load) ───────────────────────────────

function AuthErrorScreen({ error, onRetry, onSignOut }: {
  error: string; onRetry: () => void; onSignOut: () => void;
}) {
  return (
    <View style={splash.container}>
      <Particles />
      <View style={{ alignItems: 'center', gap: 16, paddingHorizontal: 40 }}>
        <Text style={{ fontSize: 44 }}>⚠️</Text>
        <Text style={[splash.logoText, { fontSize: 22, textAlign: 'center' }]}>
          Error al cargar
        </Text>
        <Text style={{ fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 22 }}>
          {error}
        </Text>
        <Pressable
          style={{ backgroundColor: COLORS.green, borderRadius: 14, paddingHorizontal: 32, paddingVertical: 13, marginTop: 8 }}
          onPress={onRetry}
        >
          <Text style={{ fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg }}>Reintentar</Text>
        </Pressable>
        <Pressable onPress={onSignOut}>
          <Text style={{ fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2, marginTop: 4 }}>
            Cerrar sesión
          </Text>
        </Pressable>
      </View>
    </View>
  );
}

// ─── Tab bar options (shared) ─────────────────────────────────────────────────

const TAB_SCREEN_OPTIONS = {
  headerShown: false,
  tabBarStyle: {
    backgroundColor: COLORS.card,
    borderTopColor: COLORS.border,
    borderTopWidth: 1,
    height: Platform.OS === 'ios' ? 80 : 58,
    paddingBottom: Platform.OS === 'ios' ? 22 : 8,
    paddingTop: 6,
    elevation: 0,
  },
  tabBarActiveTintColor: COLORS.green,
  tabBarInactiveTintColor: COLORS.muted,
  tabBarLabelStyle: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 10,
    marginTop: 1,
  },
  tabBarIconStyle: { marginBottom: -2 },
};

// ─── Stacks / Tabs ────────────────────────────────────────────────────────────

/** Stack compartido para la pestaña "Explorar" (group y admin también lo usan) */
function ExploreStack() {
  return (
    <Stack.Navigator screenOptions={{ headerShown: false }}>
      <Stack.Screen name="ExploreHome" component={HomeScreen} />
      <Stack.Screen name="GroupDetail" component={GroupDetailScreen} />
      <Stack.Screen
        name="Booking"
        component={BookingScreen}
        options={{ animation: 'slide_from_bottom' }}
      />
      <Stack.Screen name="ClientReservations" component={ClientReservationsScreen} />
      <Stack.Screen name="OpenRequest"         component={OpenRequestScreen} />
      <Stack.Screen name="GroupsMap"           component={GroupsMapScreen} />
      <Stack.Screen name="QuoteForm"           component={QuoteFormScreen} />
      <Stack.Screen name="ClientQuoteDetail"   component={ClientQuoteDetailScreen} />
      <Stack.Screen name="QuotePayment"         component={QuotePaymentScreen} />
    </Stack.Navigator>
  );
}

/** Tabs del cliente: Explorar | Mis Eventos | Publicidad | Perfil */
function ClientTabsInner() {
  const { t } = useTranslation();
  const { pendingQuotesCount } = useClientBadges();
  return (
    <Tab.Navigator screenOptions={TAB_SCREEN_OPTIONS}>
      <Tab.Screen
        name="Explorar"
        component={HomeScreen}
        options={{ tabBarLabel: t('tabs.explore'), tabBarIcon: ({ color }) => <Compass size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Mis Eventos"
        component={ClientReservationsScreen}
        options={{
          tabBarLabel: t('tabs.reservations'),
          tabBarIcon: ({ color }) => <Calendar size={20} color={color} />,
          tabBarBadge: pendingQuotesCount > 0 ? pendingQuotesCount : undefined,
        }}
      />
      <Tab.Screen
        name="Publicidad"
        component={PromocionarseScreen}
        options={{ tabBarLabel: t('tabs.ads'), tabBarIcon: ({ color }) => <Megaphone size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Perfil"
        component={ProfileScreen}
        options={{ tabBarLabel: t('tabs.profile'), tabBarIcon: ({ color }) => <User size={20} color={color} /> }}
      />
    </Tab.Navigator>
  );
}

function ClientTabs() {
  return (
    <ClientBadgesProvider>
      <ClientTabsInner />
    </ClientBadgesProvider>
  );
}

/** Tabs del talento: Panel | Bolsa | Explorar | Eventos | Perfil */
function TalentTabs() {
  const { t } = useTranslation();
  return (
    <Tab.Navigator screenOptions={TAB_SCREEN_OPTIONS}>
      <Tab.Screen
        name="Panel"
        component={TalentStatsScreen}
        options={{ tabBarLabel: t('tabs.dashboard'), tabBarIcon: ({ color }) => <LayoutDashboard size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Bolsa"
        component={TalentJobBoardScreen}
        options={{ tabBarLabel: t('tabs.jobs'), tabBarIcon: ({ color }) => <Briefcase size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Explorar"
        component={HomeScreen}
        options={{ tabBarLabel: t('tabs.explore'), tabBarIcon: ({ color }) => <Compass size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Eventos"
        component={MemberEventsScreen}
        options={{ tabBarLabel: t('tabs.events'), tabBarIcon: ({ color }) => <CalendarDays size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Perfil"
        component={ProfileScreen}
        options={{ tabBarLabel: t('tabs.profile'), tabBarIcon: ({ color }) => <User size={20} color={color} /> }}
      />
    </Tab.Navigator>
  );
}

/** Tabs del grupo: Panel | Eventos | Explorar | Publicidad | Perfil */
function GroupTabsInner() {
  const { t } = useTranslation();
  const { pendingQuotesCount } = useGroupBadges();
  return (
    <Tab.Navigator screenOptions={TAB_SCREEN_OPTIONS}>
      <Tab.Screen
        name="Panel"
        component={GroupDashboardScreen}
        options={{ tabBarLabel: t('tabs.dashboard'), tabBarIcon: ({ color }) => <LayoutDashboard size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Eventos"
        component={GroupEventsScreen}
        options={{
          tabBarLabel: t('tabs.events'),
          tabBarIcon: ({ color }) => <CalendarDays size={20} color={color} />,
          tabBarBadge: pendingQuotesCount > 0 ? pendingQuotesCount : undefined,
        }}
      />
      <Tab.Screen
        name="Explorar"
        component={HomeScreen}
        options={{ tabBarLabel: t('tabs.explore'), tabBarIcon: ({ color }) => <Compass size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Publicidad"
        component={PromocionarseScreen}
        options={{ tabBarLabel: t('tabs.ads'), tabBarIcon: ({ color }) => <Megaphone size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Perfil"
        component={ProfileScreen}
        options={{ tabBarLabel: t('tabs.profile'), tabBarIcon: ({ color }) => <User size={20} color={color} /> }}
      />
    </Tab.Navigator>
  );
}

function GroupTabs() {
  return (
    <GroupBadgesProvider>
      <GroupTabsInner />
    </GroupBadgesProvider>
  );
}

function GroupHomeWithExpress() {
  const { user } = useAuth();
  const [groupId, setGroupId] = React.useState<string | null>(null);

  React.useEffect(() => {
    if (!user?.id) return;
    supabase
      .from('groups')
      .select('id')
      .eq('owner_id', user.id)
      .single()
      .then(({ data }: { data: { id: string } | null }) => { if (data) setGroupId(data.id); });
  }, [user?.id]);

  return (
    <ExpressProvider groupId={groupId}>
      <View style={{ flex: 1 }}>
        <GroupTabs />
        <ExpressCarousel />
      </View>
    </ExpressProvider>
  );
}

/** Tabs del admin: Panel | Talentos | Anuncios | Explorar | Perfil */
function AdminTabs() {
  const { t } = useTranslation();
  return (
    <Tab.Navigator screenOptions={TAB_SCREEN_OPTIONS}>
      <Tab.Screen
        name="Panel"
        component={AdminDashboardScreen}
        options={{ tabBarLabel: t('tabs.dashboard'), tabBarIcon: ({ color }) => <LayoutDashboard size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Talentos"
        component={AdminTalentsScreen}
        options={{ tabBarLabel: t('tabs.talents'), tabBarIcon: ({ color }) => <Users size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Anuncios"
        component={AdApprovalScreen}
        options={{ tabBarLabel: t('tabs.ads'), tabBarIcon: ({ color }) => <Megaphone size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Explorar"
        component={ExploreStack}
        options={{ tabBarLabel: t('tabs.explore'), tabBarIcon: ({ color }) => <Compass size={20} color={color} /> }}
      />
      <Tab.Screen
        name="Perfil"
        component={ProfileScreen}
        options={{ tabBarLabel: t('tabs.profile'), tabBarIcon: ({ color }) => <User size={20} color={color} /> }}
      />
    </Tab.Navigator>
  );
}

// ─── Root Navigator ───────────────────────────────────────────────────────────

export default function AppNavigator() {
  const { session, role, loading, error, signOut, refetchProfile, user, profile } = useAuth();
  const navigationRef = useNavigationContainerRef();

  // Registra el push token cuando hay sesión activa
  usePushNotifications(user?.id ?? null);

  // Holds a dispatchId to navigate once the navigator mounts (cold-start race)
  const pendingExpressId  = useRef<string | null>(null);
  // True when pendingExpressId was already consumed via initialNavState.
  // Prevents onReady from navigating a second time on top of the initial state.
  const initialStateUsed  = useRef(false);

  // ── Deep link desde notificación ───────────────────────────────────────────
  useEffect(() => {
    const sub = ExpoNotifications.addNotificationResponseReceivedListener(response => {
      const data = response.notification.request.content.data as Record<string, unknown>;

      // Express dispatch deep-link — navigate directly to IncomingExpress
      if (data?.type === 'express_dispatch' && data?.dispatchId) {
        const id = data.dispatchId as string;
        if (navigationRef.isReady()) {
          (navigationRef as any).navigate('IncomingExpress', { dispatchId: id });
        } else {
          pendingExpressId.current = id;
        }
        return;
      }

      const screen = data?.screen as string | undefined;
      if (!navigationRef.isReady()) return;

      if (screen === 'AdvertisingPackages') {
        navigationRef.navigate('AdvertisingPackages' as never);
      } else if (screen === 'Explorar') {
        navigationRef.navigate('Explorar' as never);
      } else if (screen === 'Notifications') {
        navigationRef.navigate('Notifications' as never);
      } else if (screen === 'GroupReservations' && role === 'group') {
        navigationRef.navigate('GroupReservations' as never);
      } else if (screen === 'ClientReservations' && role === 'client') {
        navigationRef.navigate('ClientReservations' as never);
      } else if (screen === 'Wallet' && (role === 'group' || role === 'admin')) {
        navigationRef.navigate('Wallet' as never);
      } else if (screen === 'GroupEarnings' && role === 'group') {
        navigationRef.navigate('GroupEarnings' as never);
      } else if (!screen && data?.reservation_id) {
        navigationRef.navigate('Notifications' as never);
      }
      // Reservas, cotizaciones, etc. se manejan desde NotificationsScreen.handleNavigation
    });
    return () => sub.remove();
  }, []);

  // Cold-start check fires on mount — ~5ms, before auth hydrates
  const [coldStartCheckDone, setColdStartCheckDone] = useState(false);
  useEffect(() => {
    ExpoNotifications.getLastNotificationResponseAsync()
      .then(response => {
        if (!response) return;
        const data = response.notification.request.content.data as Record<string, unknown>;
        if (data?.type === 'express_dispatch' && data?.dispatchId) {
          pendingExpressId.current = data.dispatchId as string;
        }
      })
      .catch(() => {})
      .finally(() => setColdStartCheckDone(true));
  }, []);

  // ── 1. Cargando: validando JWT + consultando profiles ──────────────────────
  if (loading || !coldStartCheckDone) {
    return <SplashLoader />;
  }

  // ── 2. Sin sesión → pantallas de autenticación ────────────────────────────
  if (!session) {
    // Deep link: daricefy://g/:referralCode → abre RegisterScreen con código pre-relleno
    const authLinking = {
      prefixes: ['daricefy://'],
      config: {
        screens: {
          Intro:    '',
          Login:    'login',
          Register: {
            path: 'g/:referralCode',
            parse: { referralCode: (code: string) => code.toUpperCase() },
          },
        },
      },
    };

    return (
      <NavigationContainer linking={authLinking}>
        <Stack.Navigator screenOptions={{ headerShown: false, animation: 'fade' }}>
          <Stack.Screen name="Intro"    component={IntroScreen} />
          <Stack.Screen name="Login"    component={LoginScreen} />
          <Stack.Screen name="Register" component={RegisterScreen} />
        </Stack.Navigator>
      </NavigationContainer>
    );
  }

  // ── 3. Sesión activa pero el perfil falló al cargarse ─────────────────────
  //       (RLS bloqueó, red caída, perfil no existe, rol inválido)
  //       NUNCA cae silenciosamente a ClientTabs
  if (error || !role) {
    return (
      <AuthErrorScreen
        error={error ?? 'No se encontró el perfil de usuario.'}
        onRetry={refetchProfile}
        onSignOut={signOut}
      />
    );
  }

  // ── 4a. Guard de ubicación ────────────────────────────────────────────────
  // Bloquea el acceso hasta que profiles.state Y profiles.country estén llenos.
  // Admins quedan exentos (pueden operar sin ubicación fija).
  if (role !== 'admin' && (!profile?.state || !profile?.country)) {
    return <LocationRequestScreen />;
  }

  // ── 4. Enrutado por rol ────────────────────────────────────────────────────
  // La ciudad ya NO bloquea la app. Si profile.city es null,
  // AuthContext detecta silenciosamente por GPS o usa 'Guadalajara' como fallback.
  // El usuario puede cambiar su ciudad en Perfil → "Cambiar ciudad".

  // If a cold-start Express push was tapped, start the navigator already at IncomingExpress
  // so GroupHome never renders first (no dashboard flash).
  // Mark initialStateUsed so onReady does NOT navigate a second time on top.
  const hasPendingExpress = role === 'group' && !!pendingExpressId.current;
  if (hasPendingExpress) initialStateUsed.current = true;

  const initialNavState = hasPendingExpress
    ? {
        routes: [
          { name: 'GroupHome' },
          { name: 'IncomingExpress', params: { dispatchId: pendingExpressId.current } },
        ] as any[],
        index: 1,
      }
    : undefined;

  return (
    <LocationGate>
    <NavigationContainer
      ref={navigationRef}
      initialState={initialNavState as any}
      onReady={() => {
        // Warm-start / OOM race: listener fired before navigator was ready,
        // stored the id in pendingExpressId but initialNavState was already
        // rendered as undefined. Replay the navigate now that the ref is ready.
        const id = pendingExpressId.current;
        pendingExpressId.current = null;
        if (id && role === 'group' && !initialStateUsed.current) {
          (navigationRef as any).navigate('IncomingExpress', { dispatchId: id });
        }
        initialStateUsed.current = false;
      }}
    >
      <Stack.Navigator screenOptions={{ headerShown: false, animation: 'fade' }}>

        {role === 'admin' && (
          <>
            <Stack.Screen name="AdminHome"          component={AdminTabs} />
            <Stack.Screen name="AdminVerifications" component={AdminVerificationsScreen} />
            <Stack.Screen name="AdminDisputes"      component={AdminDisputesScreen} />
            <Stack.Screen name="AdminGroups"        component={AdminGroupsScreen} />
            <Stack.Screen name="AdminStats"         component={AdminStatsScreen} />
            <Stack.Screen name="AdminFinancial"     component={AdminFinancialScreen} />
            <Stack.Screen name="AdminMap"           component={AdminMapScreen} />
            <Stack.Screen name="GroupDetail"        component={GroupDetailScreen} />
            <Stack.Screen name="QuoteForm"          component={QuoteFormScreen} />
            <Stack.Screen name="AdminWithdrawals"   component={AdminWithdrawalsScreen} />
            <Stack.Screen name="AdminMediaReview"   component={AdminMediaReviewScreen} />
            <Stack.Screen name="AdApproval"          component={AdApprovalScreen} />
            <Stack.Screen name="Wallet"             component={WalletScreen} />
            <Stack.Screen name="Withdraw"           component={WithdrawScreen} />
            <Stack.Screen name="Notifications"      component={NotificationsScreen} />
            <Stack.Screen name="EventPayouts"       component={EventPayoutsScreen} />
          </>
        )}

        {role === 'group' && (
          <>
            <Stack.Screen name="GroupHome"            component={GroupHomeWithExpress} />
            <Stack.Screen name="IncomingExpress"      component={IncomingExpressScreen} options={{ presentation: 'fullScreenModal', animation: 'fade' }} />
            <Stack.Screen name="GroupReservations"    component={GroupReservationsScreen} />
            <Stack.Screen name="GroupConfirmBooking"  component={GroupConfirmBookingScreen} />
            <Stack.Screen name="EventTimer"           component={EventTimerScreen} />
            <Stack.Screen name="GroupVerification"    component={GroupVerificationScreen} />
            <Stack.Screen name="ExtraHours"           component={ExtraHoursScreen} />
            <Stack.Screen name="GroupEarnings"        component={GroupEarningsScreen} />
            <Stack.Screen name="GroupCalendar"        component={GroupCalendarScreen} />
            <Stack.Screen name="GroupAvailability"    component={GroupAvailabilityScreen} />
            <Stack.Screen name="GroupJobBoard"        component={GroupJobBoardScreen} />
            <Stack.Screen name="GroupSentInvitations" component={GroupSentInvitationsScreen} />
            <Stack.Screen name="GroupBenefits"        component={GroupBenefitsScreen} />
            <Stack.Screen name="GroupQuotes"          component={GroupQuotesScreen} />
            <Stack.Screen name="GroupQuoteDetail"     component={GroupQuoteDetailScreen} />
            <Stack.Screen name="GroupStats"           component={GroupStatsScreen} />
            <Stack.Screen name="OpenRequests"         component={GroupOpenRequestsScreen} />
            <Stack.Screen name="ProposeRequest"       component={GroupProposeRequestScreen} />
            <Stack.Screen name="GroupTalentSearch"    component={GroupTalentSearchScreen} />
            <Stack.Screen name="TalentProfile"        component={TalentProfileScreen} />
            <Stack.Screen name="Wallet"               component={WalletScreen} />
            <Stack.Screen name="Withdraw"             component={WithdrawScreen} />
            <Stack.Screen name="Chat"                 component={ChatScreen} />
            <Stack.Screen name="Notifications"          component={NotificationsScreen} />
            <Stack.Screen name="Profile"               component={ProfileScreen} />
            <Stack.Screen name="EventPayouts"          component={EventPayoutsScreen} />
            <Stack.Screen name="Promocionarse"         component={PromocionarseScreen} />
            <Stack.Screen name="CreateAdvertisement"   component={CreateAdvertisementScreen} />
            <Stack.Screen name="AdvertisingPackages"   component={AdvertisingPackagesScreen} />
            <Stack.Screen name="Bidding"               component={BiddingScreen} />
            <Stack.Screen name="Recommendation"        component={RecommendationScreen} />
            <Stack.Screen name="Plus"                  component={PlusScreen} />
            {/* ── Explorar / B2B: grupo contrata a otro grupo ── */}
            <Stack.Screen name="GroupDetail"           component={GroupDetailScreen} />
            <Stack.Screen name="Booking"               component={BookingScreen} options={{ animation: 'slide_from_bottom' }} />
            <Stack.Screen name="ClientReservations"    component={ClientReservationsScreen} />
            <Stack.Screen name="GuidedRequest"         component={GuidedRequestScreen} />
            <Stack.Screen name="GroupsMap"             component={GroupsMapScreen} />
            <Stack.Screen name="QuoteForm"             component={QuoteFormScreen} />
            <Stack.Screen name="ClientQuoteDetail"     component={ClientQuoteDetailScreen} />
            <Stack.Screen name="OpenRequest"           component={OpenRequestScreen} />
            <Stack.Screen name="QuotePayment"          component={QuotePaymentScreen} />
          </>
        )}

        {role === 'talent' && (
          <>
            <Stack.Screen name="TalentHome"              component={TalentTabs} />
            <Stack.Screen name="ClientVerification"      component={ClientVerificationScreen} />
            <Stack.Screen name="GroupDetail"             component={GroupDetailScreen} />
            <Stack.Screen
              name="Booking"
              component={BookingScreen}
              options={{ animation: 'slide_from_bottom' }}
            />
            <Stack.Screen name="ClientReservations"      component={ClientReservationsScreen} />
            <Stack.Screen name="GroupReservationDetail"  component={GroupConfirmBookingScreen} />
            <Stack.Screen name="EventTimer"              component={EventTimerScreen} />
            <Stack.Screen name="TalentStats"             component={TalentStatsScreen} />
            <Stack.Screen name="GroupQuotes"             component={GroupQuotesScreen} />
            <Stack.Screen name="GroupQuoteDetail"        component={GroupQuoteDetailScreen} />
            <Stack.Screen name="Profile"                 component={ProfileScreen} />
            <Stack.Screen name="Notifications"           component={NotificationsScreen} />
            <Stack.Screen name="CreateAdvertisement"    component={CreateAdvertisementScreen} />
            <Stack.Screen name="AdvertisingPackages"    component={AdvertisingPackagesScreen} />
            <Stack.Screen name="OpenRequest"            component={OpenRequestScreen} />
            <Stack.Screen name="GuidedRequest"          component={GuidedRequestScreen} />
            <Stack.Screen name="GroupsMap"              component={GroupsMapScreen} />
            <Stack.Screen name="QuoteForm"              component={QuoteFormScreen} />
            <Stack.Screen name="ClientQuoteDetail"      component={ClientQuoteDetailScreen} />
          </>
        )}

        {role === 'client' && (
          <>
            <Stack.Screen name="Home"               component={ClientTabs} />
            <Stack.Screen name="GroupDetail"        component={GroupDetailScreen} />
            <Stack.Screen
              name="Booking"
              component={BookingScreen}
              options={{ animation: 'slide_from_bottom' }}
            />
            <Stack.Screen name="ClientReservations" component={ClientReservationsScreen} />
            <Stack.Screen name="LiveEvent"          component={LiveEventScreen} />
            <Stack.Screen name="EventTimer"         component={EventTimerScreen} />
            <Stack.Screen name="Chat"               component={ChatScreen} />
            <Stack.Screen name="QuoteForm"          component={QuoteFormScreen} />
            <Stack.Screen name="ClientQuoteDetail"  component={ClientQuoteDetailScreen} />
            <Stack.Screen name="QuotePayment"        component={QuotePaymentScreen} />
            <Stack.Screen name="OpenRequest"        component={OpenRequestScreen} />
            <Stack.Screen name="GuidedRequest"      component={GuidedRequestScreen} />
            <Stack.Screen name="GroupsMap"          component={GroupsMapScreen} />
            <Stack.Screen name="ClientVerification"    component={ClientVerificationScreen} />
            <Stack.Screen name="ClientExtraHours"      component={ClientExtraHoursScreen} />
            <Stack.Screen name="CreateAdvertisement"   component={CreateAdvertisementScreen} />
            <Stack.Screen name="AdvertisingPackages"   component={AdvertisingPackagesScreen} />
            <Stack.Screen name="Profile"               component={ProfileScreen} />
            <Stack.Screen name="Notifications"         component={NotificationsScreen} />
          </>
        )}

      </Stack.Navigator>
    </NavigationContainer>
    </LocationGate>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const splash = StyleSheet.create({
  container: {
    flex: 1, backgroundColor: COLORS.bg,
    alignItems: 'center', justifyContent: 'center', paddingHorizontal: 40,
  },
  // Energy background
  glowBlob: {
    position: 'absolute',
    width: 440, height: 440, borderRadius: 220,
    backgroundColor: 'rgba(0,230,118,0.035)',
  },
  ring: {
    position: 'absolute',
    borderWidth: 1.5,
    borderColor: COLORS.green,
  },
  beam: {
    position: 'absolute',
    width: 1, height: 620,
    backgroundColor: 'rgba(0,230,118,0.055)',
  },
  energyDot: {
    position: 'absolute',
    width: 8, height: 8, borderRadius: 4,
  },
  // Logo
  logoText: {
    fontFamily: FONTS.title, fontSize: 52, color: COLORS.text,
    letterSpacing: -0.5, textAlign: 'center',
  },
  logoX: {
    color: COLORS.green,
    textShadowColor: COLORS.green,
    textShadowRadius: 14,
    textShadowOffset: { width: 0, height: 0 },
  },
  tagline:  { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2, marginTop: 10, letterSpacing: 0.6, textAlign: 'center' },
  subtitle: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 6, letterSpacing: 0.3, textAlign: 'center', fontStyle: 'italic', paddingHorizontal: 10 },
  dotsRow:  { flexDirection: 'row', alignItems: 'center', marginTop: 52 },
  bodySemiBold: { fontFamily: FONTS.bodySemiBold },
});
