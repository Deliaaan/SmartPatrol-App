#!/usr/bin/env bash
set -euo pipefail

REPO="Deliaaan/SmartPatrol-App"
OWNER="${REPO%/*}"
TITLE="Sistema embebible de trazabilidad de inspecciones físicas no invasivo mediante NFC"

if [[ $# != 1 ]]; then
  echo "Uso: $0 FECHA_INICIO_SPRINT_1 (AAAA-MM-DD)" >&2
  exit 1
fi
for command in gh jq python3; do
  command -v "$command" >/dev/null || { echo "Falta $command" >&2; exit 1; }
done

dates=$(python3 - "$1" <<'PY'
import datetime
import sys

try:
    start = datetime.date.fromisoformat(sys.argv[1])
    if start.isoformat() != sys.argv[1]:
        raise ValueError()
except ValueError:
    sys.exit("Fecha inválida; use AAAA-MM-DD.")
for i in range(5):
    print((start + datetime.timedelta(days=i * 14)).isoformat(),
          (start + datetime.timedelta(days=i * 14 + 13)).isoformat())
PY
)
mapfile -t sprint_dates <<< "$dates"
gh auth status >/dev/null
repo_data=$(gh api graphql -f query='
  query($owner:String!, $name:String!) {
    repository(owner:$owner, name:$name) {
      id viewerPermission owner { id login }
    }
  }' -f owner="$OWNER" -f name="${REPO#*/}")
repo_id=$(jq -er '.data.repository.id' <<< "$repo_data")
owner_id=$(jq -er '.data.repository.owner.id' <<< "$repo_data")
permission=$(jq -er '.data.repository.viewerPermission' <<< "$repo_data")
case "$permission" in ADMIN|MAINTAIN|WRITE) ;; *) echo "Se requiere acceso de escritura al repositorio." >&2; exit 1;; esac

echo "Se creará un proyecto nuevo y 22 issues en $REPO. No vuelva a ejecutar el script después de un error sin revisar los recursos ya creados."
read -r -p "Escriba CREAR para continuar: " confirmation
[[ "$confirmation" == CREAR ]] || { echo "Cancelado."; exit 1; }
trap 'echo "Error: revise el proyecto y los recursos ya creados antes de volver a ejecutar el script." >&2' ERR

project=$(gh api graphql -f query='
  mutation($owner:ID!, $repo:ID!, $title:String!) {
    createProjectV2(input:{ownerId:$owner, repositoryId:$repo, title:$title}) {
      projectV2 { id number url }
    }
  }' -f owner="$owner_id" -f repo="$repo_id" -f title="$TITLE")
project_id=$(jq -er '.data.createProjectV2.projectV2.id' <<< "$project")
project_number=$(jq -er '.data.createProjectV2.projectV2.number' <<< "$project")
project_url=$(jq -er '.data.createProjectV2.projectV2.url' <<< "$project")
echo "Proyecto creado: $project_url"

fields=$(gh project field-list "$project_number" --owner "$OWNER" --format json --limit 100)
status_id=$(jq -er '.fields[] | select(.name == "Status") | .id' <<< "$fields")
gh api graphql -f query='
  mutation($field:ID!) {
    updateProjectV2Field(input:{fieldId:$field, singleSelectOptions:[
      {name:"Backlog", color:GRAY, description:"Trabajo pendiente"},
      {name:"Ready", color:BLUE, description:"Listo para empezar"},
      {name:"In Progress", color:YELLOW, description:"En desarrollo"},
      {name:"In Review", color:PURPLE, description:"En revisión"},
      {name:"Done", color:GREEN, description:"Completado"}
    ]}) { projectV2Field { ... on ProjectV2SingleSelectField { id } } }
  }' -f field="$status_id" >/dev/null

gh project field-create "$project_number" --owner "$OWNER" --name Priority --data-type SINGLE_SELECT --single-select-options High,Medium,Low >/dev/null
gh project field-create "$project_number" --owner "$OWNER" --name Component --data-type SINGLE_SELECT --single-select-options Backend,Web-Embeddable,Mobile-NFC,DevOps,QA >/dev/null
gh project field-create "$project_number" --owner "$OWNER" --name Estimate --data-type SINGLE_SELECT --single-select-options 1,2,3,5,8 >/dev/null

iteration_json=$(printf '%s\n' "${sprint_dates[@]}" | jq -Rsc '
  split("\n") | map(select(length > 0)) |
  to_entries | map({title:("Sprint " + ((.key + 1)|tostring)), startDate:(.value | split(" ")[0]), duration:14})')
sprint_start=${sprint_dates[0]%% *}
iteration_query='
  mutation($project:ID!, $start:Date!, $iterations:[ProjectV2Iteration!]!) {
    createProjectV2Field(input:{projectId:$project, name:"Sprint", dataType:ITERATION,
      iterationConfiguration:{duration:14, startDate:$start, iterations:$iterations}}) {
      projectV2Field { ... on ProjectV2IterationField {
        id configuration { iterations { id title } completedIterations { id title } }
      } }
    }
  }'
iteration_result=$(jq -n --arg query "$iteration_query" --arg project "$project_id" \
  --arg start "$sprint_start" --argjson iterations "$iteration_json" \
  '{query:$query, variables:{project:$project, start:$start, iterations:$iterations}}' |
  gh api graphql --input -)
sprint_id=$(jq -er '.data.createProjectV2Field.projectV2Field.id' <<< "$iteration_result")

for layout in BOARD_LAYOUT ROADMAP_LAYOUT; do
  [[ "$layout" == BOARD_LAYOUT ]] && view_name="Kanban" || view_name="Roadmap"
  gh api graphql -f query='
    mutation($project:ID!, $name:String!, $layout:ProjectV2ViewLayout!) {
      createProjectV2View(input:{projectId:$project, name:$name, layout:$layout}) {
        projectV2View { id }
      }
    }' -f project="$project_id" -f name="$view_name" -f layout="$layout" >/dev/null
done

labels=$(gh label list --repo "$REPO" --limit 1000 --json name)
for label in epic feature bug security nfc embeddable documentation; do
  if ! jq -e --arg label "$label" 'any(.[]; .name == $label)' <<< "$labels" >/dev/null; then
    gh label create "$label" --repo "$REPO"
  fi
done
for i in {1..5}; do
  end_date=${sprint_dates[$((i-1))]##* }
  gh api "repos/$REPO/milestones" -f title="Sprint $i" -f due_on="${end_date}T23:59:59Z" >/dev/null
done

fields=$(gh project field-list "$project_number" --owner "$OWNER" --format json --limit 100)
field_id() { jq -er --arg name "$1" '.fields[] | select(.name == $name) | .id' <<< "$fields"; }
option_id() { jq -er --arg field "$1" --arg option "$2" '.fields[] | select(.name == $field) | .options[] | select(.name == $option) | .id' <<< "$fields"; }
set_option() {
  gh project item-edit --project-id "$project_id" --id "$1" --field-id "$(field_id "$2")" \
    --single-select-option-id "$(option_id "$2" "$3")" >/dev/null
}
create_issue() {
  local title=$1 sprint=$2 component=$3 priority=$4 estimate=$5 labels=$6 body=$7 url item iteration
  url=$(gh issue create --repo "$REPO" --title "$title" --body "$body" --label "$labels" --milestone "Sprint $sprint")
  echo "Creado: $url" >&2
  item=$(gh project item-add "$project_number" --owner "$OWNER" --url "$url" --format json --jq .id)
  iteration=$(jq -er --arg title "Sprint $sprint" '.data.createProjectV2Field.projectV2Field.configuration | (.iterations + .completedIterations)[] | select(.title == $title) | .id' <<< "$iteration_result")
  set_option "$item" Status Backlog
  set_option "$item" Priority "$priority"
  set_option "$item" Component "$component"
  set_option "$item" Estimate "$estimate"
  gh project item-edit --project-id "$project_id" --id "$item" --field-id "$sprint_id" --iteration-id "$iteration" >/dev/null
  printf '%s\n' "$url"
}
link_child() {
  local parent=$1 child=$2 child_id
  child_id=$(gh api "repos/$REPO/issues/${child##*/}" --jq .id)
  gh api "repos/$REPO/issues/${parent##*/}/sub_issues" -F "sub_issue_id=$child_id" >/dev/null
}
child() {
  local url
  url=$(create_issue "$@")
  link_child "$epic" "$url"
}

epic=$(create_issue "Épica 1: Arquitectura y Base de Datos" 1 Backend High 8 epic \
"## Objetivo
Definir la arquitectura, los datos, el entorno y la seguridad del sistema.

## Criterios de aceptación
- [ ] Se completan y revisan todos los subissues de la épica.")
child "Diseñar modelo entidad-relación" 1 Backend High 5 feature \
"## Criterios de aceptación
- [ ] El modelo incluye empresas, usuarios, zonas, tags NFC, rutas/patrullajes, registros y evidencias.
- [ ] Se documentan relaciones, claves, restricciones y aislamiento por empresa.
- [ ] El modelo se revisa con los responsables técnicos."
child "Configurar repositorio, CI/CD y entorno de desarrollo" 1 DevOps High 5 feature \
"## Criterios de aceptación
- [ ] Se documentan requisitos y pasos reproducibles de instalación y ejecución.
- [ ] CI ejecuta las comprobaciones y pruebas disponibles en cada cambio.
- [ ] El despliegue y la configuración de secretos se documentan sin incluir credenciales."
child "Definir arquitectura de seguridad y validación NFC" 1 Backend High 5 feature,security,nfc,embeddable \
"## Criterios de aceptación
- [ ] Se documentan autenticación JWT, autorización por empresa y gestión de claves API para integración.
- [ ] Se definen ciclo de vida, rotación y revocación de credenciales y protección del widget.
- [ ] Se describen la validación de tags y las limitaciones de confiar solo en el UID, incluido el riesgo de clonación."

epic=$(create_issue "Épica 2: Backend y Motor de Auditoría" 2 Backend High 8 epic \
"## Objetivo
Implementar la API y el motor de auditoría de inspecciones.

## Criterios de aceptación
- [ ] Se completan y revisan todos los subissues de la épica.")
child "Implementar API de zonas, tags y programación de patrullajes" 2 Backend High 8 feature,nfc \
"## Criterios de aceptación
- [ ] La API permite crear, consultar, modificar y eliminar zonas, tags y patrullajes autorizados.
- [ ] La programación incluye días, horarios, frecuencia y requisitos de cada punto.
- [ ] Se validan entradas, permisos y aislamiento de datos por empresa."
child "Registrar checkpoints con validación NFC y hora del servidor" 2 Backend High 8 feature,nfc,security \
"## Criterios de aceptación
- [ ] El endpoint comprueba el tag, la asignación del usuario y el checkpoint de la ronda.
- [ ] El servidor genera y conserva el timestamp de auditoría; el cliente no puede sobrescribirlo.
- [ ] Se rechazan registros inválidos y se cubren los riesgos de clonación identificados en el diseño."
child "Almacenar evidencias fotográficas de forma segura" 2 Backend High 5 feature,security \
"## Criterios de aceptación
- [ ] Las fotos se vinculan con el registro y la empresa correctos.
- [ ] Se validan tipo y tamaño y el acceso queda restringido a usuarios autorizados.
- [ ] Se documentan retención, protección y eliminación de evidencias."
child "Detectar omisiones y retrasos y generar reportes" 2 Backend High 8 feature \
"## Criterios de aceptación
- [ ] Se identifican rondas incompletas y checkpoints tardíos según su programación.
- [ ] Los reportes muestran ronda, punto, estado y marcas de tiempo relevantes.
- [ ] Se prueban límites de horario, zonas horarias y rondas que cruzan medianoche."

epic=$(create_issue "Épica 3: Módulo Web Administrativo Embebible" 3 Web-Embeddable High 8 epic,embeddable \
"## Objetivo
Entregar la administración y el monitoreo como módulo embebible.

## Criterios de aceptación
- [ ] Se completan y revisan todos los subissues de la épica.")
child "Empaquetar panel administrativo como componente embebible" 3 Web-Embeddable High 8 feature,embeddable,security \
"## Criterios de aceptación
- [ ] El panel se integra en un sitio externo mediante componente o SDK documentado.
- [ ] Los estilos se aíslan con Shadow DOM o un iframe seguro.
- [ ] La autenticación por token evita exponer claves secretas en el navegador."
child "Crear interfaz de configuración de patrullajes" 3 Web-Embeddable High 8 feature,embeddable \
"## Criterios de aceptación
- [ ] El administrador configura calendario, días, horarios y frecuencia.
- [ ] Permite asignar checkpoints y exigir foto o descripción por punto.
- [ ] Los cambios se validan y persisten mediante la API."
child "Crear dashboard de monitoreo y exportación" 3 Web-Embeddable High 8 feature,embeddable \
"## Criterios de aceptación
- [ ] El dashboard muestra el estado actualizado de las rondas.
- [ ] Permite consultar historial y evidencias según los permisos del usuario.
- [ ] Permite exportar reportes de auditoría."

epic=$(create_issue "Épica 4: Aplicación Móvil con Lectura NFC" 4 Mobile-NFC High 8 epic,nfc \
"## Objetivo
Permitir al personal ejecutar rondas NFC y registrar evidencias.

## Criterios de aceptación
- [ ] Se completan y revisan todos los subissues de la épica.")
child "Autenticar personal y mostrar rondas del turno" 4 Mobile-NFC High 5 feature,security \
"## Criterios de aceptación
- [ ] El personal inicia sesión de forma segura y puede cerrar sesión.
- [ ] La aplicación muestra únicamente las rondas asignadas al turno y su estado.
- [ ] Las sesiones expiradas requieren autenticación nuevamente."
child "Leer tags NFC para desbloquear checkpoints" 4 Mobile-NFC High 8 feature,nfc \
"## Criterios de aceptación
- [ ] La aplicación lee el tag NFC y solicita su validación al backend.
- [ ] Solo un checkpoint validado habilita el registro de evidencias.
- [ ] Se informa al usuario si el tag es incorrecto, no se puede leer o no es compatible."
child "Capturar evidencias dinámicas e incidencias" 4 Mobile-NFC High 8 feature \
"## Criterios de aceptación
- [ ] El formulario refleja los requisitos configurados para el punto.
- [ ] Exige una foto tomada con cámara cuando corresponda y permite observaciones e incidencias.
- [ ] No se envía un registro sin las evidencias obligatorias."
child "Sincronizar registros al recuperar conectividad" 4 Mobile-NFC High 8 feature \
"## Criterios de aceptación
- [ ] Los registros pendientes se conservan protegidos durante una pérdida de señal.
- [ ] Al reconectar se reintenta la sincronización sin crear duplicados.
- [ ] La interfaz distingue registros pendientes, aceptados y rechazados; la hora oficial la asigna el servidor."

epic=$(create_issue "Épica 5: Pruebas Piloto y Documentación" 5 QA High 8 epic \
"## Objetivo
Validar el sistema en un piloto y documentar su integración.

## Criterios de aceptación
- [ ] Se completan y revisan todos los subissues de la épica.")
child "Probar integración del widget en un sitio externo" 5 QA High 5 feature,embeddable \
"## Criterios de aceptación
- [ ] Un sitio de prueba externo incrusta el módulo y autentica una sesión de prueba.
- [ ] Se verifican aislamiento de estilos, errores de autenticación y operaciones principales.
- [ ] Se registran resultados y defectos reproducibles."
child "Realizar pruebas de campo con tags NFC físicos" 5 QA High 5 feature,nfc \
"## Criterios de aceptación
- [ ] Se ejecuta una ronda en un almacén simulado con tags físicos.
- [ ] Se verifican lectura, evidencias, omisiones, retrasos y recuperación de señal.
- [ ] Se documentan dispositivos, resultados y defectos reproducibles."
child "Documentar integración técnica del módulo web" 5 Web-Embeddable Medium 5 documentation,embeddable \
"## Criterios de aceptación
- [ ] La guía incluye requisitos, instalación, configuración y ejemplo de incrustación.
- [ ] Explica autenticación, permisos, protección de credenciales y aislamiento de estilos.
- [ ] Se valida la guía en un sitio externo sin depender de conocimientos implícitos."

echo "Proyecto creado: $project_url"
echo "En la vista Roadmap, seleccione el campo Sprint como campo de planificación; compruebe que Kanban esté agrupado por Status."
