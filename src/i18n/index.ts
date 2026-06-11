import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import * as Localization from 'expo-localization';

import es from './locales/es.json';
import en from './locales/en.json';

const locale = Localization.getLocales()[0]?.languageTag ?? 'es';
const lng = locale.startsWith('en') ? 'en' : 'es';

i18n
  .use(initReactI18next)
  .init({
    resources: {
      es: { translation: es },
      en: { translation: en },
    },
    lng,
    fallbackLng: 'es',
    interpolation: { escapeValue: false },
  });

export default i18n;
