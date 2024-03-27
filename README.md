> [!IMPORTANT]
> Die "alte" API wird von Daikin voraussichtlich im April 2024 abgeschaltet bzw. der bisher benutzte API-KEY für ungültig erklärt. Ab diesem Zeitpunkt wird das Modul bis einschließlich der Version 1.3.6 nicht mehr funktionieren. Es ist dann zwingend ein Update auf die neue Modul-Version 2.x.x erforderlich, um die neue OPEN-API nutzen zu können.

# DaikinCloud Support für FHEM
Es handelt sich um ein Modul für FHEM, um Klimageräte von Daikin über die Daikin-Cloud zu steuern.

Damit die Klimageräte gesteuert werden können, ist es erforderlich, dass der Registrierungsprozess in der ONECTA-App abgeschlossen worden ist. Das heißt die Innengeräte sind mit dem Internet verbunden und in der Daikin-Cloud ersichtlich.

# Kompatibilität

Alle Geräte (z.B. Klimasplitgeräte, Multisplitgeräte, Altherma), die über die ONECTA-App mit der DaikinCloud verbunden worden sind, sollten mit diesem Modul angezeigt bzw. gesteuert werden können.

# Verwendung 

1. Integration des Moduls DaikinCloud in den FHEM-UPDATE-Prozess. Folgender Befehl in FHEM führt dazu, dass das Modul installiert bzw. im Rahmen von "update" automatisch mit aktualisiert wird:
```
update add https://raw.githubusercontent.com/frank-lie/DaikinCloud/main/controls_DaikinCloud.txt
```
2. Danach den Update-Prozess in FHEM starten mit:
```
update
```
3. Sollte der Update-Prozess unter Nummer 1 und 2 fehlschlagen, muss die Datei "FHEM/58_DaikinCloud.pm" manuell in den Ordner fhem/FHEM kopiert werden und kann in FHEM wie folgt neu geladen werden:
```
reload 58_DaikinCloud.pm
```
4. Nach dem Update von Modul-Version 1.x.x auf Modul-Version 2.x.x ist ein Neustart von FHEM erforderlich, damit alle neuen Parameter ordnungsgemäß geladen werden. Alle bereits angelegten Devices können problemlos weiterverwendet werden.
```
shutdown restart
```   
5. In FHEM muss ein Master Device für die Kommunikation mit der Cloud angelegt werden. 
```
define Daikin_Master DaikinCloud
```
6. In den INTERNALS des Master Devices ist der AUTHORIZATION_LINK hinterlegt, der angeklickt werden muss, um dem Modul den Zugriff auf die Daikin-Cloud zu ermöglichen. Ihr werdet auf die Seite von Daikin geleitet, müsst euch dort einloggen und den Nutzungsbedingungen zustimmen und die Freigabe der Daten erlauben. Anschließend werdet ihr auf die Redirect-Url weitergeleitet.
   
7. Da die Redirect-Url aktuell noch nicht individuell gesetzt werden kann, erfolgt aktuell eine Weiterleitung an `https://my.home-assistant.io/redirect/oauth`, um den Authorisierungscode zu bekommen. Bevor ihr eine Fehlermeldung wie `Invalid paramaters given` wegklickt, ist der komplette Link (`https://my.home-assistant.io/redirect/oauth/?code=xxxxxxxxxxxx`) der Internetseite aus dem Browser in die Zwischenablage zu kopieren und in FHEM als set-command einzugeben:
```
set Daikin_Master AuthCode <kompletter Link der Rückgabe-URL>
```
8. Die Einrichtung des Master Devices ist damit abgeschlossen. Die Innengeräte werden standardmäßig beim Abruf der Daten aus der Cloud als Device in FHEM angelegt. Standardmäßig werden die Daten aus der Cloud alle 900 Sekunden abgerufen / aktualisiert.

# Einschränkungen

1. Aktuell hat Daikin Request-Limits für das Abrufen der Cloud-Daten und das Senden von Kommandos hinterlegt. Pro Tag können maximal 200 Anfragen und pro Minute maximal 20 Anfragen gesendet werden. Sowohl bei dem 24-Stunden-Limit als auch dem 1-Minuten-Limit handelt es sich um gleitende Zeitfenster, die fortlaufend aktualisiert bzw. immer zeitweise zurückgesetzt werden.

2. Aktuell sind (noch) nicht alle Datenpunkte in der neuen OPEN-API enthalten. Es fehlen insbesondere: dryKeepSetting, fanMotorRotationSpeed, heatExchangerTemperature, suctionTemperature und diverse wifi-readings. Ferner sind z.B. demandControl und demandValue nicht vorhanden, so dass aktuell auch keine Bedarfssteuerung möglich ist. Es handelt sich hierbei um Einschränkungen, die die neue OPEN-API mit sich bringt und damit durch das Modul auch nicht behoben oder beseitigt werden können. Sobald Daikin die Daten in der neuen OPEN-API zur Verfügung stellt, stehen diese automatisch auch (wieder) in FHEM zur Verfügung.
