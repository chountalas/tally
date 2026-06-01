#ifndef LegacyXLSBridge_h
#define LegacyXLSBridge_h

char *TallyCreateCSVFromXLSFile(const char *filePath, char **errorMessage);
void TallyFreeCString(char *string);

#endif
