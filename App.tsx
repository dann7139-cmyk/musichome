import {
  DMSans_400Regular,
  DMSans_500Medium,
  DMSans_600SemiBold,
} from '@expo-google-fonts/dm-sans';
import { Syne_800ExtraBold } from '@expo-google-fonts/syne';
import { DancingScript_700Bold } from '@expo-google-fonts/dancing-script';
import { Platform } from 'react-native';
const StripeProvider = Platform.OS === 'web'
  ? ({ children }: any) => children
  : require('@stripe/stripe-react-native').StripeProvider;
import { useFonts } from 'expo-font';
import * as SplashScreenExpo from 'expo-splash-screen';
import React, { useCallback } from 'react';
import { View } from 'react-native';
import { AuthProvider } from './src/context/AuthContext';
import AppNavigator from './navigation/AppNavigator';
import './src/i18n';

SplashScreenExpo.preventAutoHideAsync();

// Llave PUBLICABLE de Stripe (no es secreta — va en el cliente). Modo LIVE
// desde 2026-09-09: los cobros por Stripe (regalos, pagar a meses, y todo
// lo que caiga a create-payment-intent) son reales. DEBE ser del MISMO par
// que STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET en Supabase (todos live).
const STRIPE_PK_PLACEHOLDER = 'pk_live_51T38Eo2OHRU9DGsYsg0nvuuItrSpnKlXtzuFqnqsN1riwdkfQTVkVR11Y15RBj7FqVcArQ7fo2JTC9A08QmTyuol00Za0Nxt5n';

export default function App() {
  const [fontsLoaded] = useFonts({
    Syne_800ExtraBold,
    DMSans_400Regular,
    DMSans_500Medium,
    DMSans_600SemiBold,
    DancingScript_700Bold,
  });

  const onLayoutRootView = useCallback(async () => {
    if (fontsLoaded) {
      await SplashScreenExpo.hideAsync();
    }
  }, [fontsLoaded]);

  if (!fontsLoaded) return null;

  return (
    <StripeProvider publishableKey={STRIPE_PK_PLACEHOLDER} merchantCountryCode="MX">
      <AuthProvider>
        <View style={{ flex: 1, backgroundColor: '#040404' }} onLayout={onLayoutRootView}>
          <AppNavigator />
        </View>
      </AuthProvider>
    </StripeProvider>
  );
}
