#include "LegacyXLSBridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "xls.h"

typedef struct {
    char *buffer;
    size_t length;
    size_t capacity;
} STCSVBuffer;

static char *st_strdup(const char *string) {
    if (string == NULL) {
        return NULL;
    }

    size_t length = strlen(string) + 1;
    char *copy = malloc(length);
    if (copy == NULL) {
        return NULL;
    }

    memcpy(copy, string, length);
    return copy;
}

static int st_reserve(STCSVBuffer *builder, size_t additionalLength) {
    size_t required = builder->length + additionalLength + 1;
    if (required <= builder->capacity) {
        return 1;
    }

    size_t nextCapacity = builder->capacity == 0 ? 1024 : builder->capacity;
    while (nextCapacity < required) {
        nextCapacity *= 2;
    }

    char *nextBuffer = realloc(builder->buffer, nextCapacity);
    if (nextBuffer == NULL) {
        return 0;
    }

    builder->buffer = nextBuffer;
    builder->capacity = nextCapacity;
    return 1;
}

static int st_append_bytes(STCSVBuffer *builder, const char *bytes, size_t length) {
    if (!st_reserve(builder, length)) {
        return 0;
    }

    memcpy(builder->buffer + builder->length, bytes, length);
    builder->length += length;
    builder->buffer[builder->length] = '\0';
    return 1;
}

static int st_append_cstring(STCSVBuffer *builder, const char *string) {
    return st_append_bytes(builder, string, strlen(string));
}

static int st_append_character(STCSVBuffer *builder, char character) {
    return st_append_bytes(builder, &character, 1);
}

static int st_append_csv_field(STCSVBuffer *builder, const char *value) {
    const char *cursor = value == NULL ? "" : value;
    if (!st_append_character(builder, '"')) {
        return 0;
    }

    while (*cursor != '\0') {
        if (*cursor == '"') {
            if (!st_append_cstring(builder, "\"\"")) {
                return 0;
            }
        } else {
            if (!st_append_character(builder, *cursor)) {
                return 0;
            }
        }
        cursor += 1;
    }

    return st_append_character(builder, '"');
}

static const char *st_cell_string(const xlsCell *cell, char numberBuffer[64]) {
    if (cell == NULL || cell->isHidden) {
        return "";
    }

    if (cell->id == XLS_RECORD_RK || cell->id == XLS_RECORD_MULRK || cell->id == XLS_RECORD_NUMBER) {
        snprintf(numberBuffer, 64, "%.15g", cell->d);
        return numberBuffer;
    }

    if (cell->id == XLS_RECORD_FORMULA || cell->id == XLS_RECORD_FORMULA_ALT) {
        if (cell->l == 0) {
            snprintf(numberBuffer, 64, "%.15g", cell->d);
            return numberBuffer;
        }

        if (cell->str != NULL) {
            if (strcmp(cell->str, "bool") == 0) {
                return ((int)cell->d) != 0 ? "true" : "false";
            }
            if (strcmp(cell->str, "error") == 0) {
                return "*error*";
            }
            return cell->str;
        }

        return "";
    }

    if (cell->str != NULL) {
        return cell->str;
    }

    return "";
}

static void st_set_error(char **errorMessage, const char *message) {
    if (errorMessage == NULL) {
        return;
    }

    *errorMessage = st_strdup(message);
}

char *TallyCreateCSVFromXLSFile(const char *filePath, char **errorMessage) {
    if (errorMessage != NULL) {
        *errorMessage = NULL;
    }

    if (filePath == NULL) {
        st_set_error(errorMessage, "The selected .xls file could not be opened.");
        return NULL;
    }

    xls_error_t workbookError = LIBXLS_OK;
    xlsWorkBook *workbook = xls_open_file(filePath, "UTF-8", &workbookError);
    if (workbook == NULL) {
        st_set_error(errorMessage, xls_getError(workbookError));
        return NULL;
    }

    if (workbook->sheets.count == 0) {
        xls_close_WB(workbook);
        st_set_error(errorMessage, "The Excel workbook does not contain any worksheets.");
        return NULL;
    }

    xlsWorkSheet *worksheet = xls_getWorkSheet(workbook, 0);
    if (worksheet == NULL) {
        xls_close_WB(workbook);
        st_set_error(errorMessage, "The first worksheet could not be opened.");
        return NULL;
    }

    xls_error_t worksheetError = xls_parseWorkSheet(worksheet);
    if (worksheetError != LIBXLS_OK) {
        xls_close_WS(worksheet);
        xls_close_WB(workbook);
        st_set_error(errorMessage, xls_getError(worksheetError));
        return NULL;
    }

    STCSVBuffer builder = {0};
    for (WORD row = 0; row <= worksheet->rows.lastrow; row++) {
        for (WORD column = 0; column <= worksheet->rows.lastcol; column++) {
            if (column > 0 && !st_append_character(&builder, ',')) {
                st_set_error(errorMessage, "The workbook is too large to convert.");
                free(builder.buffer);
                xls_close_WS(worksheet);
                xls_close_WB(workbook);
                return NULL;
            }

            xlsCell *cell = xls_cell(worksheet, row, column);
            char numberBuffer[64] = {0};
            if (!st_append_csv_field(&builder, st_cell_string(cell, numberBuffer))) {
                st_set_error(errorMessage, "The workbook is too large to convert.");
                free(builder.buffer);
                xls_close_WS(worksheet);
                xls_close_WB(workbook);
                return NULL;
            }
        }

        if (!st_append_character(&builder, '\n')) {
            st_set_error(errorMessage, "The workbook is too large to convert.");
            free(builder.buffer);
            xls_close_WS(worksheet);
            xls_close_WB(workbook);
            return NULL;
        }
    }

    if (builder.buffer == NULL) {
        builder.buffer = st_strdup("");
    }

    xls_close_WS(worksheet);
    xls_close_WB(workbook);
    return builder.buffer;
}

void TallyFreeCString(char *string) {
    free(string);
}
