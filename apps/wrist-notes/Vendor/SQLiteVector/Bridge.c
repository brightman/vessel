#include "src/sqlite-vector.h"
#include "Bridge.h"
int wristnotes_vector_init(sqlite3 *db, char **error) { return sqlite3_vector_init(db, error, 0); }
