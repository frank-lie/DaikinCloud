# DaikinCloud Support für FHEM

> [!IMPORTANT]
> Die "alte" API wird von Daikin voraussichtlich im April 2024 abgeschaltet bzw. der bisher benutzte API-KEY für ungültig erklärt. Ab diesem Zeitpunkt wird das Modul bis einschließlich der Version 1.3.6 nicht mehr funktionieren. Es ist dann zwingend ein Update auf die neue Modul-Version 2.x.x erforderlich, um die neue OPEN-API nutzen zu können.

Es handelt sich um ein Modul für FHEM, um Klimageräte von Daikin über die Daikin-Cloud zu steuern.

Damit die Klimageräte gesteuert werden können, ist es erforderlich, dass der Registrierungsprozess in der ONECTA-App abgeschlossen worden ist. Das heißt die Innengeräte sind mit dem Internet verbunden und in der Daikin-Cloud ersichtlich.

## Kompatibilität

Alle Geräte (z.B. Klimasplitgeräte, Multisplitgeräte, Altherma), die über die ONECTA-App mit der DaikinCloud verbunden worden sind, sollten mit diesem Modul angezeigt bzw. gesteuert werden können.

## Installation und Verwendung 

1. Damit das Modul in FHEM verwendet werden kann, ist der folgende update-Befehl in FHEM auszuführen:
   
   ```
   update all https://raw.githubusercontent.com/frank-lie/DaikinCloud/main/controls_DaikinCloud.txt
   ```
   Alternativ kann auch die Datei "FHEM/58_DaikinCloud.pm" manuell in den Ordner fhem/FHEM kopiert werden.   
> [!TIP]
> Um automatisch immer die aktuelle Version des Moduls im Rahmen des FHEM-Befehls `update` zu erhalten, kann man den Link auch generell als Update-Quelle hinzufügen:
>```
>update add https://raw.githubusercontent.com/frank-lie/DaikinCloud/main/controls_DaikinCloud.txt
>``` 

2. Nach einem Update von FHEM sollte in der Regel ein Neustart von FHEM gemacht werden, damit alle Änderungen ordnungsgemäß geladen werden:
   ```
   shutdown restart
   ```   
3. Für die Kommunikation mit der Daikin-Cloud ist in FHEM zunächst ein Master-Device anzulegen: 
   ```
   define Daikin_Master DaikinCloud
   ```
4. Sobald das Master-Device erstellt worden ist, kann der AUTHORIZATION_LINK (zu finden als INTERNAL im Master-Device) aufgerufen werden, um den Authorisierungsprozess zu starten. Ihr werdet auf die Seite von Daikin geleitet, müsst euch dort einloggen, den Nutzungsbedingungen zustimmen und die Freigabe der Daten erlauben. Anschließend werdet ihr auf die Redirect-Url weitergeleitet.
   
5. Da die Redirect-Url im Developer-Portal von Daikin aktuell noch nicht konfigurierbar ist, erfolgt übergangsweise eine Weiterleitung/Mitbenutzung von `https://my.home-assistant.io/redirect/oauth`, um den Authorisierungscode zu bekommen. Bevor ihr eine Fehlermeldung wie `"Invalid paramaters given"` wegklickt, muss der komplette Link der Internetseite aus dem Browser (`https://my.home-assistant.io/redirect/oauth/?code=xxxxxxxxxxxx`) in die Zwischenablage kopiert und in FHEM als set-command eingegeben werden:
   ```
   set Daikin_Master AuthCode <kompletter Link der Rückgabe-URL>
   ```
6. Mit dem Setzen des Authorisierungscodes bekommt FHEM die erforderlichen Token für den Zugriff auf die Daikin-Cloud übermittelt. Die Einrichtung des Master-Devices ist damit abgeschlossen. Die Innengeräte werden standardmäßig beim Abruf der Daten aus der Cloud als Device in FHEM angelegt. Standardmäßig werden die Daten aus der Cloud alle 900 Sekunden abgerufen / aktualisiert.

## Einschränkungen

1. Aktuell hat Daikin Request-Limits für das Abrufen der Cloud-Daten und das Senden von Kommandos hinterlegt. Pro Tag können maximal 200 Anfragen und pro Minute maximal 20 Anfragen gesendet werden. Sowohl bei dem 24-Stunden-Limit als auch dem 1-Minuten-Limit handelt es sich um gleitende Zeitfenster, die fortlaufend aktualisiert bzw. immer zeitweise zurückgesetzt werden.

2. Aktuell sind (noch) nicht alle Datenpunkte in der neuen OPEN-API enthalten. Es fehlen insbesondere: dryKeepSetting, fanMotorRotationSpeed, heatExchangerTemperature, suctionTemperature und diverse wifi-readings. Ferner sind z.B. demandControl und demandValue nicht vorhanden, so dass aktuell auch keine Bedarfssteuerung möglich ist. Es handelt sich hierbei um Einschränkungen, die die neue OPEN-API mit sich bringt und damit durch das Modul auch nicht behoben oder beseitigt werden können. Sobald Daikin die Daten in der neuen OPEN-API zur Verfügung stellt, stehen diese automatisch auch (wieder) in FHEM zur Verfügung.
