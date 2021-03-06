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

#include "catalog/pg_type_d.h"
#include "nodes/parsenodes.h"
#include "nodes/primnodes.h"
#include "nodes/relation.h"
#include "optimizer/pathnode.h"
#include "optimizer/paths.h"

#include "optimizer/cypher_pathnode.h"
#include "optimizer/cypher_paths.h"
#include "utils/ag_func.h"

typedef enum cypher_clause_kind
{
    CYPHER_CLAUSE_NONE,
    CYPHER_CLAUSE_CREATE
} cypher_clause_kind;

static set_rel_pathlist_hook_type prev_set_rel_pathlist_hook;

static void set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel, Index rti,
                             RangeTblEntry *rte);
static cypher_clause_kind get_cypher_clause_kind(RangeTblEntry *rte);
static void handle_cypher_create_clause(PlannerInfo *root, RelOptInfo *rel,
                                        Index rti, RangeTblEntry *rte);

void set_rel_pathlist_init(void)
{
    prev_set_rel_pathlist_hook = set_rel_pathlist_hook;
    set_rel_pathlist_hook = set_rel_pathlist;
}

void set_rel_pathlist_fini(void)
{
    set_rel_pathlist_hook = prev_set_rel_pathlist_hook;
}

static void set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel, Index rti,
                             RangeTblEntry *rte)
{
    if (prev_set_rel_pathlist_hook)
        prev_set_rel_pathlist_hook(root, rel, rti, rte);

    switch (get_cypher_clause_kind(rte))
    {
    case CYPHER_CLAUSE_CREATE:
        handle_cypher_create_clause(root, rel, rti, rte);
        break;
    case CYPHER_CLAUSE_NONE:
        break;
    default:
        ereport(ERROR, (errmsg_internal("invalid cypher_clause_kind")));
    }
}

/*
 * Check to see if the rte is a Cypher clause. An rte is only a Cypher clause
 * if it is a subquery, with the last entry in its target list, that is a
 * FuncExpr.
 */
static cypher_clause_kind get_cypher_clause_kind(RangeTblEntry *rte)
{
    TargetEntry *te;
    FuncExpr *fe;

    // If it's not a subquery, it's not a Cypher clause.
    if (rte->rtekind != RTE_SUBQUERY)
        return CYPHER_CLAUSE_NONE;

    // A Cypher clause function is always the last entry.
    te = llast(rte->subquery->targetList);

    // If the last entry is not a FuncExpr, it's not a Cypher clause.
    if (!IsA(te->expr, FuncExpr))
        return CYPHER_CLAUSE_NONE;

    fe = (FuncExpr *)te->expr;

    if (is_oid_ag_func(fe->funcid, "_cypher_create_clause"))
        return CYPHER_CLAUSE_CREATE;
    else
        return CYPHER_CLAUSE_NONE;
}

// replace all possible paths with our CustomPath
static void handle_cypher_create_clause(PlannerInfo *root, RelOptInfo *rel,
                                        Index rti, RangeTblEntry *rte)
{
    TargetEntry *te;
    FuncExpr *fe;
    Const *c;
    List *custom_private;
    CustomPath *cp;

    // Add the pattern to the CustomPath
    te = (TargetEntry *)llast(rte->subquery->targetList);
    fe = (FuncExpr *)te->expr;
    c = linitial(fe->args);
    custom_private = list_make1(DatumGetPointer(c->constvalue));

    // Discard any pre-existing paths
    rel->pathlist = NIL;
    rel->partial_pathlist = NIL;

    cp = create_cypher_create_path(root, rel, custom_private);
    add_path(rel, (Path *)cp);
}
