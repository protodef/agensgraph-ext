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

#include "access/genam.h"
#include "access/heapam.h"
#include "access/htup.h"
#include "access/htup_details.h"
#include "access/skey.h"
#include "access/stratnum.h"
#include "catalog/indexing.h"
#include "fmgr.h"
#include "storage/lockdefs.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/relcache.h"

#include "catalog/ag_graph.h"
#include "catalog/ag_label.h"
#include "utils/ag_cache.h"
#include "utils/graphid.h"

// INSERT INTO ag_catalog.ag_label
// VALUES (label_name, label_graph, label_id, label_kind, label_relation)
Oid insert_label(const char *label_name, Oid label_graph, int32 label_id,
                 char label_kind, Oid label_relation)
{
    NameData label_name_data;
    Datum values[Natts_ag_label];
    bool nulls[Natts_ag_label];
    Relation ag_label;
    HeapTuple tuple;
    Oid label_oid;

    /*
     * NOTE: Is it better to make use of label_id and label_kind domain types
     *       than to use assert to check label_id and label_kind are valid?
     */
    AssertArg(label_name);
    AssertArg(OidIsValid(label_graph));
    AssertArg(label_id_is_valid(label_id));
    AssertArg(label_kind == LABEL_KIND_VERTEX ||
              label_kind == LABEL_KIND_EDGE);
    AssertArg(OidIsValid(label_relation));

    namestrcpy(&label_name_data, label_name);
    values[Anum_ag_label_name - 1] = NameGetDatum(&label_name_data);
    nulls[Anum_ag_label_name - 1] = false;

    values[Anum_ag_label_graph - 1] = ObjectIdGetDatum(label_graph);
    nulls[Anum_ag_label_graph - 1] = false;

    values[Anum_ag_label_id - 1] = Int32GetDatum(label_id);
    nulls[Anum_ag_label_id - 1] = false;

    values[Anum_ag_label_kind - 1] = CharGetDatum(label_kind);
    nulls[Anum_ag_label_kind - 1] = false;

    values[Anum_ag_label_relation - 1] = ObjectIdGetDatum(label_relation);
    nulls[Anum_ag_label_relation - 1] = false;

    ag_label = heap_open(ag_label_relation_id(), RowExclusiveLock);

    tuple = heap_form_tuple(RelationGetDescr(ag_label), values, nulls);

    /*
     * CatalogTupleInsert() is originally for PostgreSQL's catalog. However,
     * it is used at here for convenience.
     */
    label_oid = CatalogTupleInsert(ag_label, tuple);

    heap_close(ag_label, RowExclusiveLock);

    return label_oid;
}

// DELETE FROM ag_catalog.ag_label WHERE relation = relation
void delete_label(Oid relation)
{
    ScanKeyData scan_keys[1];
    Relation ag_label;
    SysScanDesc scan_desc;
    HeapTuple tuple;

    ScanKeyInit(&scan_keys[0], Anum_ag_label_relation, BTEqualStrategyNumber,
                F_OIDEQ, ObjectIdGetDatum(relation));

    ag_label = heap_open(ag_label_relation_id(), RowExclusiveLock);
    scan_desc = systable_beginscan(ag_label, ag_label_relation_index_id(),
                                   true, NULL, 1, scan_keys);

    tuple = systable_getnext(scan_desc);
    if (!HeapTupleIsValid(tuple))
    {
        ereport(ERROR,
                (errcode(ERRCODE_UNDEFINED_TABLE),
                 errmsg("label (relation=%u) does not exist", relation)));
    }

    CatalogTupleDelete(ag_label, &tuple->t_self);

    systable_endscan(scan_desc);
    heap_close(ag_label, RowExclusiveLock);
}

Oid get_label_oid(const char *label_name, Oid label_graph)
{
    label_cache_data *cache_data;

    cache_data = search_label_name_graph_cache(label_name, label_graph);
    if (cache_data)
        return cache_data->oid;
    else
        return InvalidOid;
}

int32 get_label_id(const char *label_name, Oid label_graph)
{
    label_cache_data *cache_data;

    cache_data = search_label_name_graph_cache(label_name, label_graph);
    if (cache_data)
        return cache_data->id;
    else
        return INVALID_LABEL_ID;
}

Oid get_label_relation(const char *label_name, Oid label_graph)
{
    label_cache_data *cache_data;

    cache_data = search_label_name_graph_cache(label_name, label_graph);
    if (cache_data)
        return cache_data->relation;
    else
        return InvalidOid;
}

char *get_label_relation_name(const char *label_name, Oid label_graph)
{
    return get_rel_name(get_label_relation(label_name, label_graph));
}

PG_FUNCTION_INFO_V1(_label_id);

Datum _label_id(PG_FUNCTION_ARGS)
{
    Name graph_name;
    Name label_name;
    Oid graph;
    int32 id;

    if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
    {
        ereport(ERROR, (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                        errmsg("graph_name and label_name must not be null")));
    }
    graph_name = PG_GETARG_NAME(0);
    label_name = PG_GETARG_NAME(1);

    graph = get_graph_oid(NameStr(*graph_name));
    id = get_label_id(NameStr(*label_name), graph);

    PG_RETURN_INT32(id);
}

bool label_id_exists(Oid label_graph, int32 label_id)
{
    label_cache_data *cache_data;

    cache_data = search_label_graph_id_cache(label_graph, label_id);
    if (cache_data)
        return true;
    else
        return false;
}
