/*
 * Copyright 2020 Bitnine Co., Ltd.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "postgres.h"

#include "fmgr.h"

PG_FUNCTION_INFO_V1(cypher);

Datum cypher(PG_FUNCTION_ARGS)
{
    const char *s;

    s = PG_ARGISNULL(0) ? "NULL" : PG_GETARG_CSTRING(0);

    ereport(ERROR, (errmsg_internal("unhandled cypher(cstring) function call"),
                    errdetail_internal("%s", s)));

    PG_RETURN_NULL();
}

PG_FUNCTION_INFO_V1(_cypher_create_clause);

Datum _cypher_create_clause(PG_FUNCTION_ARGS)
{
    ereport(ERROR,
            (errmsg_internal("unhandled _cypher_create_clause(internal) function call")));

    PG_RETURN_NULL();
}
