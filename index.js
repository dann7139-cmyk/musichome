import { registerRootComponent } from 'expo';
// Registra la tarea de ubicación en background ANTES de que cargue la app
import './src/utils/backgroundLocation';
import App from './App';

registerRootComponent(App);
