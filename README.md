# DaikinCloud Support für FHEM
Es handelt sich um ein Modul für FHEM, um Klimageräte von Daikin über die Daikin-Cloud zu steuern.

Damit die Klimageräte gesteuert werden können, ist es erforderlich, dass der Registrierungsprozess in der ONECTA-App abgeschlossen worden ist. Das heißt die Innengeräte sind mit dem Internet verbunden und in der Daikin-Cloud ersichtlich.

# Kompatibilität

Folgende in den Daikin-Geräten integrierte WLAN-Module sind hierfür grundsätzlich kompatibel:
- BRP069C4x
- BRP069B4x

# Verwendung 

1. Die Datei "58_DaikinCloud.pm" muss zu den anderen Modulen in den Ordner fhem/FHEM kopiert und wie folgt in FHEM geladen werden:
```
reload 58_DaikinCloud.pm
```
2. In FHEM muss ein Master Device für die Kommunikation mit der Cloud angelegt werden:
```
define Daikin_Master DaikinCloud
```
3. Den in der Onecta-App vergebenen Benutzernamen und Passwort speichern. Danach kann das tokenSet abgerufen werden:
```
set Daikin_Master username <your-email>
set Daikin_Master password <your-password>
get Daikin_Master tokenSet
```
4. Die Innengeräte werden standardmäßig beim Abruf der Daten aus der Cloud als Device in FHEM angelegt. Standardmäßig werden die Daten aus der Cloud alle 60 Sekunden abgerufen / aktualisiert.

# Thanks to
Dieser Code basiert auf der Arbeit von @Apollon77, der einen Weg gefunden hat, das tokenSet abzurufen und die HTTP-Befehle zur Cloud zu senden. Nützlich war mir auch die Portierung von @Rospogrigio nach Python. Meine Aufgabe bestand darin, einen Weg zu finden, den Code nach perl zu portieren und für eine Integration in FHEM zu modifizieren und zu verfeinern.
