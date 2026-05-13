[about]

## Tabletas gráficas

Una tableta gráfica es un dispositivo de entrada con un lápiz sin batería que registra posición absoluta, presión, inclinación y a veces rotación. A diferencia de un ratón, el lápiz va exactamente donde lo colocas, y las apps de dibujo pueden responder a cuánta fuerza ejerces — haciendo que el trabajo digital se sienta más cercano al papel.

## MockTab

MockTab es un driver nativo de macOS para tabletas gráficas Wacom. Es compatible con tabletas USB y Bluetooth de las familias Intuos, Cintiq, Bamboo e Intuos Pro — hardware que el propio driver de Wacom ha dejado de soportar en versiones modernas de macOS.

MockTab se ejecuta completamente en espacio de usuario, sin extensión de kernel ni daemon en segundo plano. Configúralo una vez y no molesta más.

[tabletArea]

## Área activa

El área activa es la parte de la superficie de la tableta que se mapea a tu pantalla. La entrada del lápiz fuera de este rectángulo se ignora.

**Redimensionar** — Arrastra cualquier control en la vista previa para reposicionar o cambiar el tamaño del área activa. Mantén **Shift** mientras arrastras una esquina para bloquear la proporción de aspecto a las proporciones de tu pantalla. También puedes escribir valores exactos en los campos Width y Height.

**Lock Aspect Ratio** — Mantiene la proporción tableta-pantalla para que el cursor recorra distancias iguales horizontal y verticalmente. Desactívalo si quieres estirar o comprimir el mapeo deliberadamente.

**Reset to Full** — Restaura el área activa a toda la superficie de la tableta. Esta acción se puede deshacer (⌘Z).

## Calibración (Pen Displays)

El botón **Calibrate** abre una superposición a pantalla completa donde tocas dianas con mira con la punta del lápiz. Esto corrige la brecha de paralaje entre la punta del lápiz y el cursor en pantalla causada por el cristal de la pantalla.

Tras calibrar, usa **Manual Fine-Tune** si queda un pequeño desplazamiento constante — por ejemplo cuando el paralaje varía ligeramente según tu ángulo de visión.

[penFeel]

## Curva de presión

La curva de presión controla cómo se mapea la presión del lápiz a la presión de salida. Una curva cóncava (hacia arriba) hace que los trazos suaves se registren con más intensidad; una curva convexa (hacia abajo) requiere más fuerza para el mismo efecto.

**Preajustes de Tip Feel** — Soft, Medium, Firm y Custom. Elegir un preajuste establece la curva; ajustar un punto de la curva cambia a Custom automáticamente.

## Suavizado

El suavizado reduce las vibraciones de alta frecuencia en la señal de entrada. Valores más altos producen trazos más limpios a costa de un pequeño retraso al inicio y al final de cada trazo. Para trabajo rápido y gestual, los valores bajos se sienten más inmediatos.

## Distancia de doble clic

Define cuán cerca deben estar dos toques para registrarse como doble clic. Auméntala si los dobles clics no se registran; disminúyela si se producen dobles clics accidentales durante el dibujo normal.

[buttons]

## Diagrama del lápiz

El diagrama en la parte superior muestra los botones de tu lápiz. Pulsa cualquier botón mientras la ventana está abierta para verlo resaltado — útil para identificar qué botón físico corresponde a qué ranura de asignación.

## Tipos de asignación

- **Botones del ratón** — clic izquierdo, derecho, central o doble clic
- **Atajos de teclado** — haz clic en el campo de atajo y pulsa cualquier combinación de teclas
- **Modificadores mantenidos** — ⌘ ⌥ ⇧ ⌃ se mantienen mientras el botón esté pulsado
- **Acciones especiales** — Display Toggle, Eraser, selección de modo del Touch Ring

## Touch Ring

El anillo admite varios slots de modo. Cada slot tiene su propia acción en sentido horario y antihorario (desplazar, hacer zoom o repetir una tecla). Asigna **Ring Cycle** a un botón para recorrer los modos, o **Ring: Slot N** para saltar directamente a un slot específico. El **multiplicador de velocidad** controla con qué rapidez se disparan las acciones por grado de rotación.

## Borrador

La punta del borrador tiene su propia asignación, configurada en la sección del lápiz. La mayoría de las apps de dibujo cambian automáticamente a su herramienta de borrado cuando reciben eventos de proximidad del borrador — no se requiere ninguna asignación especial a menos que quieras anular ese comportamiento.

## Overrides por app

La barra de overrides en la parte superior te permite asignar botones diferentes para una aplicación específica. Los overrides se activan automáticamente cuando esa app pasa a primer plano. La configuración global se aplica en todos los demás casos.

[display]

## Mapeo de pantalla

El mapeo de pantalla controla a qué pantalla se mapea el área activa de la tableta.

**All Displays** — la tableta abarca todo tu escritorio de forma proporcional. Úsalo cuando trabajas con varios monitores.

**Single Display** — el área activa se mapea a una pantalla específica. Elige una pantalla de la lista; la vista previa se actualiza para mostrar el mapeo.

**Display Toggle** — asigna la acción Display Toggle a una tecla express o al botón del barrel para recorrer las pantallas conectadas sin abrir las preferencias.

[devices]

## Dispositivos conectados

El panel Dispositivos lista todas las tabletas y herramientas de lápiz que MockTab ha detectado. Cada fila muestra el nombre del dispositivo, el tipo de conexión (USB o Bluetooth) y el estado actual.

## Registro de herramientas

Cuando se detecta un lápiz, MockTab registra su código de herramienta. Si un código de herramienta no se reconoce, aparece como "Unknown tool" en el registro. Puedes asignar un nombre y una asignación de punta a herramientas desconocidas manualmente.

## Detección de conflictos

Si otro driver de tableta (como el driver oficial de Wacom) está en ejecución, MockTab detecta el conflicto y muestra una advertencia. Dos drivers compitiendo por el mismo dispositivo HID pueden causar comportamientos erráticos; cierra el driver en conflicto antes de usar MockTab.

[profiles]

## Perfiles

Un perfil es una instantánea guardada de toda tu configuración de tableta — área activa, curva de presión, asignaciones de botones y mapeo de pantalla. Cambiar de perfil aplica toda la configuración al instante.

**Auto-restore** — activa el interruptor en un perfil para que MockTab lo active automáticamente cuando se conecte esta tableta.

## Crear y renombrar

Haz clic en **Save as New Profile** para guardar la configuración actual. Haz doble clic en el nombre de un perfil para renombrarlo.

## Overrides por app en perfiles

Los overrides por app se almacenan como parte del perfil activo. Al cambiar de perfil, los overrides cambian con él.

## Importar / Exportar

Arrastra una tarjeta de perfil al Finder para exportarla como archivo JSON. Arrastra un archivo JSON sobre la lista de perfiles para importarlo. Los archivos exportados se pueden compartir entre equipos o usar como copias de seguridad.

[scratchpad]

## Scratchpad

El scratchpad es un lienzo de prueba sensible a la presión. Dibuja en él para verificar que tu lápiz registra correctamente la presión, la inclinación y la posición del trazo antes de usar una aplicación de dibujo.

La opacidad y el grosor del trazo responden a la presión de la punta. La inclinación afecta el ángulo del trazo cuando el lápiz lo soporta.

**Clear** — elimina todos los trazos del lienzo. Esta acción no se puede deshacer.

[info]

## Entrada en directo

El panel Info muestra valores en tiempo real de tu lápiz: posición X/Y, presión, inclinación, rotación, distancia de hover y estado de los botones. Estos valores se actualizan continuamente mientras el lápiz está en rango.

Es útil para diagnosticar comportamientos inesperados — por ejemplo, comprobar si la presión está alcanzando su valor máximo o si la inclinación se está reportando en absoluto.

## Diagnóstico

El botón **Copy Diagnostics** genera una instantánea de texto del estado actual del driver — versión de la app, versión de macOS, dispositivos conectados y estadísticas de entrada. Pégala en un informe de error o solicitud de soporte.

## Collect Device Data

**Collect Device Data** ejecuta una sesión de captura guiada que registra los informes HID en bruto que envía tu tableta. El resultado es un archivo JSON compacto que puedes adjuntar a una solicitud de función para añadir o mejorar el soporte para tu dispositivo.

[website]

## mocktab.org

El sitio web de MockTab en [mocktab.org](https://mocktab.org) tiene documentación, notas de versión y la lista completa de hardware compatible.

## GitHub

Los informes de errores y preguntas van a [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver/issues). El botón **Copy Diagnostics** en el panel Info genera una instantánea de texto del estado de tu driver — inclúyela con los informes de errores.
