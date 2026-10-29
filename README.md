# Prolog Control de Jornada — Fadel Transportes (Unidad CER_YPE 617)

Sistema de monitoreo operativo y auditoría de jornada laboral para motoristas, conectado en tiempo real con **Prolog App (`https://prologapp.com/prolog`)** y **GINFO Fleet Management**.

---

## 🚀 Módulos y Funcionalidades

### 1. Panel Principal (Jornadas Abiertas en Vivo)
* **Monitoreo en tiempo real** de todas las jornadas abiertas sin restricción de fecha.
* **Filtrado exclusivo de Motoristas:** Filtra automáticamente los colaboradores con función `MOTORISTA` en la unidad operativa `CER_YPE (617)`.
* **Semáforo de horas de jornada acumuladas:**
  * **Verde:** Menos de 11 horas de jornada activa.
  * 🟡 **Amarillo:** Jornadas iguales o superiores a 11 horas.
  * 🔴 **Rojo:** Jornadas iguales o superiores a 12 horas.
* **Ubicación GPS Minimalista:** Botón de mapa en cada fila que abre las coordenadas exactas de inicio y última marcación en OpenStreetMap / Leaflet interactivo.

### 2. Geocercas Poligonales y Auditoría de Anomalías
* **Diseñador de Geocercas en Mapa:** Creación y edición interactiva de perímetros poligonales (zonas autorizadas como planta CER_YPE, depósitos o centros de distribución).
* **Detección Automática de Anomalías:** Si una marcación de inicio o fin de jornada ocurre fuera de las geocercas autorizadas, el sistema la resalta con una alerta visual `❓` y la registra en el informe de anomalías.

### 3. Panel de Interjornadas (Descanso entre Turnos)
* **Cálculo de descanso retroactivo:** Lista a todos los choferes sin jornada activa y calcula el tiempo transcurrido desde su último fin de jornada hasta el presente.
* **Ordenamiento inteligente:** Ordenado automáticamente de mayor tiempo de interjornada a menor tiempo.
* **Control de 12 horas reglamentarias:**
  * 🟢 **Verde:** Descanso mayor a 12 horas (chofer descansado y listo para asignación).
  * 🔴 **Rojo:** Descanso menor a 12 horas (bloqueado para prevenir infracción de descanso mínimo).

### 4. Matriz de Días Trabajados (Presente / Descanso)
* **Matriz interactiva:** Columnas por fecha y filas por chofer.
  * **`P` (Presente):** Hubo inicio de jornada en la fecha. Al hacer clic, muestra popup con hora de inicio, hora de fin y tiempo total laborado.
  * **`DL` (Descanso Laboral):** Sin jornada en la fecha. Al hacer clic, realiza una búsqueda retroactiva hacia atrás para mostrar cuándo fue su último fin de turno y cuántas horas de interjornada acumuló.

### 5. Control de Turnos
* **Clasificación automática por franja horaria de inicio:**
  * **MAÑANA:** Inicio de jornada entre las `03:00` y las `09:59` hs.
  * **TARDE:** Inicio de jornada entre las `10:00` y las `17:59` hs.
  * **NOCHE:** Inicio de jornada entre las `18:00` y las `02:59` hs.
  * **`DL`:** Chofer en descanso laboral.

### 6. Módulo de Choferes / Motoristas
* Directorio completo de los 80 motoristas activos de la unidad.
* Formulario para editar nombre, cédula/CPF, matrícula y chapa.
* Posibilidad de dar de alta nuevos choferes con sincronización inmediata a todos los paneles y matrices.
* Conexión directa a los endpoints de Prolog (`/v2/colaboradores`) para persistencia en base de datos.

### 7. Relatorios y Auditoría
* Descarga ejecutiva en Excel (`.xlsx`) y CSV de marcaciones por rango de fechas y por chofer.
* Relatorio de anomalías por marcación fuera de geocerca.

---

## 🛠️ Arquitectura Técnica

* **Frontend:** Single-Page Application (HTML5, Tailwind CSS, Leaflet Maps, SheetJS para exportación a Excel).
* **Puente de Integración (PowerShell Backend):** `ginfo-bridge.ps1`
  * Servidor HTTP local con `System.Net.HttpListener` en puerto `3005`.
  * Manejo de sesión persistente con JWT contra la API de Prolog (`api/v3/auth`, `v2/controle-jornada`, `v2/colaboradores`).
  * Conexión con GINFO mediante cookies `PHPSESSID`.
  * Caché inteligente en memoria para evitar saturar las APIs remotas.

---

## ⚡ Inicio Rápido

1. Clona o descarga el repositorio.
2. Copia `prolog-config.example.json` como `prolog-config.json` e ingresa tus credenciales de Prolog:
```json
{
  "usuario": "TU_USUARIO_PROLOG",
  "senha": "TU_PASSWORD_PROLOG",
  "codUnidade": 617
}
```
3. Ejecuta el archivo:
```bat
Iniciar-Ginfo.bat
```
4. Abre [ginfo-control-center.html](ginfo-control-center.html) en tu navegador preferido.

---

## 🔒 Seguridad y Privacidad
El archivo `prolog-config.json` y los registros de depuración están excluidos en `.gitignore` para proteger las credenciales corporativas.
