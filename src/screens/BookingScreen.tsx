import React, { useState } from "react";
import {
  ActivityIndicator,
  Alert,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { supabase } from "../config/supabase";
import { COLORS } from "../config/theme";

export default function BookingScreen({ route, navigation }: any) {
  const { group, package: selectedPackage } = route.params;

  const [eventDate, setEventDate] = useState("");
  const [address, setAddress] = useState("");
  const [loading, setLoading] = useState(false);

  const handleBooking = async () => {
    if (!eventDate || !address) {
      Alert.alert("Error", "Completa todos los campos");
      return;
    }

    setLoading(true);

    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session) {
      Alert.alert("Error", "Debes iniciar sesión");
      setLoading(false);
      return;
    }

    // 1️⃣ Obtener comisión del país
    const { data: countryData } = await supabase
      .from("countries")
      .select("default_commission")
      .eq("code", group.country_code)
      .single();

    const commissionPercent = countryData?.default_commission || 0;

    const totalPrice = selectedPackage.price;
    const platformCommission =
      (totalPrice * commissionPercent) / 100;
    const groupEarnings =
      totalPrice - platformCommission;

    // 2️⃣ Guardar reserva con cálculo
    const { error } = await supabase.from("reservations").insert([
      {
        group_id: group.id,
        package_id: selectedPackage.id,
        client_id: session.user.id,
        event_date: eventDate,
        address: address,
        total_price: totalPrice,
        platform_commission: platformCommission,
        group_earnings: groupEarnings,
        status: "pending",
      },
    ]);

    setLoading(false);

    if (error) {
      Alert.alert("Error", error.message);
    } else {
      Alert.alert(
        "Reserva enviada",
        `Comisión plataforma: $${platformCommission}\nGanancia grupo: $${groupEarnings}`
      );
      navigation.popToTop();
    }
  };

  return (
    <View style={styles.container}>
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.content}>
          <Text style={styles.title}>Confirmar Reserva</Text>

          <View style={styles.packageBox}>
            <Text style={styles.packageName}>
              {selectedPackage.name}
            </Text>
            <Text style={styles.packagePrice}>
              ${selectedPackage.price}
            </Text>
          </View>

          <Text style={styles.label}>Fecha del Evento</Text>
          <TextInput
            style={styles.input}
            placeholder="YYYY-MM-DD"
            placeholderTextColor="#666"
            value={eventDate}
            onChangeText={setEventDate}
          />

          <Text style={styles.label}>Dirección</Text>
          <TextInput
            style={styles.input}
            placeholder="Dirección completa"
            placeholderTextColor="#666"
            value={address}
            onChangeText={setAddress}
          />

          <Pressable
            style={styles.button}
            onPress={handleBooking}
            disabled={loading}
          >
            {loading ? (
              <ActivityIndicator color="#000" />
            ) : (
              <Text style={styles.buttonText}>
                Confirmar Reserva
              </Text>
            )}
          </Pressable>
        </View>
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  content: {
    padding: 24,
  },
  title: {
    fontSize: 24,
    fontWeight: "700",
    color: COLORS.text,
    marginBottom: 24,
  },
  packageBox: {
    backgroundColor: COLORS.card,
    padding: 16,
    borderRadius: 14,
    marginBottom: 24,
  },
  packageName: {
    fontSize: 18,
    fontWeight: "600",
    color: COLORS.primary,
  },
  packagePrice: {
    fontSize: 18,
    fontWeight: "700",
    color: COLORS.text,
  },
  label: {
    color: COLORS.textSecondary,
    marginBottom: 6,
    marginTop: 12,
  },
  input: {
    backgroundColor: COLORS.card,
    borderRadius: 12,
    padding: 14,
    color: COLORS.text,
  },
  button: {
    marginTop: 30,
    backgroundColor: COLORS.primary,
    paddingVertical: 16,
    borderRadius: 14,
    alignItems: "center",
  },
  buttonText: {
    color: "#000",
    fontWeight: "700",
  },
});