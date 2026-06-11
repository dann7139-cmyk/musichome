import VideoPlayer from '../components/ui/VideoPlayer';
import { MapPin } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../config/supabase';
import { COLORS } from '../config/theme';

export default function GroupDetailScreen({ route, navigation }: any) {
  const { group } = route.params;
  const [packages, setPackages] = useState<any[]>([]);

  useEffect(() => {
    fetchPackages();
  }, []);

  const fetchPackages = async () => {
    const { data } = await supabase
      .from('packages')
      .select('*')
      .eq('group_id', group.id);

    if (data) setPackages(data);
  };

  return (
    <View style={styles.container}>
      <SafeAreaView style={{ flex: 1 }}>
        <ScrollView showsVerticalScrollIndicator={false}>
          
          {/* VIDEO */}
          {group.promo_video && (
            <VideoPlayer
              uri={group.promo_video}
              style={styles.video}
              contentFit="cover"
              nativeControls
            />
          )}

          <View style={styles.content}>
            <Text style={styles.title}>{group.name}</Text>

            <View style={styles.locationRow}>
              <MapPin size={16} color={COLORS.textSecondary} />
              <Text style={styles.location}>
                {group.city}, {group.country}
              </Text>
            </View>

            <Text style={styles.sectionTitle}>
              Paquetes Disponibles
            </Text>

            {packages.map((pkg) => (
              <View key={pkg.id} style={styles.card}>
                <Text style={styles.packageTitle}>
                  {pkg.name}
                </Text>

                <Text style={styles.description}>
                  {pkg.description}
                </Text>

                <Text style={styles.price}>
                  ${pkg.price}
                </Text>

                <Pressable
                  style={styles.reserveButton}
                  onPress={() =>
                    navigation.navigate('Booking', {
                      group,
                      package: pkg,
                    })
                  }
                >
                  <Text style={styles.reserveButtonText}>
                    Reservar este paquete
                  </Text>
                </Pressable>
              </View>
            ))}
          </View>
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  video: {
    width: '100%',
    height: 250,
  },
  content: {
    padding: 24,
  },
  title: {
    fontSize: 28,
    fontWeight: '700',
    color: COLORS.text,
    marginBottom: 6,
  },
  locationRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginBottom: 24,
  },
  location: {
    color: COLORS.textSecondary,
  },
  sectionTitle: {
    fontSize: 20,
    fontWeight: '600',
    color: COLORS.text,
    marginBottom: 16,
  },
  card: {
    backgroundColor: COLORS.card,
    padding: 20,
    borderRadius: 20,
    marginBottom: 20,
  },
  packageTitle: {
    fontSize: 18,
    fontWeight: '700',
    color: COLORS.primary,
    marginBottom: 6,
  },
  description: {
    color: COLORS.textSecondary,
    marginBottom: 10,
  },
  price: {
    fontSize: 16,
    fontWeight: '600',
    color: COLORS.text,
    marginBottom: 14,
  },
  reserveButton: {
    backgroundColor: COLORS.primary,
    paddingVertical: 14,
    borderRadius: 14,
    alignItems: 'center',
  },
  reserveButtonText: {
    color: COLORS.black,
    fontWeight: '700',
  },
});