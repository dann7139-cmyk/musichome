import {
  DMSans_400Regular,
  DMSans_500Medium,
  DMSans_600SemiBold,
} from '@expo-google-fonts/dm-sans';
import { Syne_800ExtraBold } from '@expo-google-fonts/syne';
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

const STRIPE_PK_PLACEHOLDER = 'pk_test_51T38FBRp9QVbbrs2mTzMnpmOCh2v0kkmxQvExfl55ZgMrKzy28xDHjya3Fx7Gq4tLAjq1lxrGT4IwLOkaWR6jDak00hkIWFDHQ';

export default function App() {
  const [fontsLoaded] = useFonts({
    Syne_800ExtraBold,
    DMSans_400Regular,
    DMSans_500Medium,
    DMSans_600SemiBold,
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
