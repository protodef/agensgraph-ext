%{
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

#include "nodes/makefuncs.h"
#include "nodes/nodes.h"
#include "nodes/parsenodes.h"
#include "nodes/pg_list.h"
#include "nodes/primnodes.h"
#include "nodes/value.h"
#include "parser/parser.h"

#include "nodes/ag_nodes.h"
#include "nodes/cypher_nodes.h"
#include "parser/ag_scanner.h"
#include "parser/cypher_gram.h"

// override the default action for locations
#define YYLLOC_DEFAULT(current, rhs, n) \
    do \
    { \
        if ((n) > 0) \
            current = (rhs)[1]; \
        else \
            current = -1; \
    } while (0)

#define YYMALLOC palloc
#define YYFREE pfree
%}

%locations
%name-prefix="cypher_yy"
%pure-parser

%lex-param {ag_scanner_t scanner}
%parse-param {ag_scanner_t scanner}
%parse-param {cypher_yy_extra *extra}

%union {
    /* types in cypher_yylex() */
    int integer;
    char *string;
    const char *keyword;

    /* extra types */
    bool boolean;
    Node *node;
    List *list;
}

%token <integer> INTEGER
%token <string> DECIMAL STRING

%token <string> IDENTIFIER
%token <string> PARAMETER

/* operators that have more than 1 character */
%token NOT_EQ LT_EQ GT_EQ DOT_DOT PLUS_EQ EQ_TILDE

/* keywords in alphabetical order */
%token <keyword> AND AS ASC ASCENDING
                 BY
                 CONTAINS CREATE
                 DELETE DESC DESCENDING DETACH DISTINCT
                 ENDS
                 FALSE_P
                 IN IS
                 LIMIT
                 MATCH
                 NOT NULL_P
                 OR ORDER
                 REMOVE RETURN
                 SET SKIP STARTS
                 TRUE_P
                 WHERE WITH

/* query */
%type <list> single_query query_part_init query_part_last
             reading_clause_list updating_clause_list_0 updating_clause_list_1
%type <node> reading_clause updating_clause

/* RETURN and WITH clause */
%type <node> return return_item sort_item skip_opt limit_opt with
%type <boolean> distinct_opt
%type <list> return_item_list order_by_opt sort_item_list
%type <integer> order_opt

/* MATCH clause */
%type <node> match

/* CREATE clause */
%type <node> create

/* SET and REMOVE clause */
%type <node> set set_item remove remove_item
%type <list> set_item_list remove_item_list

/* DELETE clause */
%type <node> delete
%type <boolean> detach_opt

/* common */
%type <node> where_opt

/* pattern */
%type <list> pattern simple_path_opt_parens simple_path
%type <node> path anonymous_path
             path_node path_relationship path_relationship_body
             properties_opt
%type <string> label_opt

/* expression */
%type <node> expr expr_opt atom literal map list var
%type <list> expr_list expr_list_opt map_keyval_list_opt map_keyval_list

/* names */
%type <string> property_key_name var_name var_name_opt label_name
%type <string> symbolic_name schema_name
%type <keyword> reserved_keyword

/* precedence: lowest to highest */
%left OR
%left AND
%right NOT
%nonassoc '=' NOT_EQ '<' LT_EQ '>' GT_EQ
%left '+' '-'
%left '*' '/' '%'
%left '^'
%nonassoc IN IS
%right UNARY_MINUS
%nonassoc STARTS ENDS CONTAINS
%left '[' ']' '(' ')'
%left '.'

%{
// logical operators
static Node *make_or_expr(Node *lexpr, Node *rexpr, int location);
static Node *make_and_expr(Node *lexpr, Node *rexpr, int location);
static Node *make_not_expr(Node *expr, int location);

// arithmetic operators
static Node *do_negate(Node *n, int location);
static void do_negate_float(Value *v);

// indirection
static Node *append_indirection(Node *expr, Node *selector);

// literals
static Node *make_int_const(int i, int location);
static Node *make_float_const(char *s, int location);
static Node *make_string_const(char *s, int location);
static Node *make_bool_const(bool b, int location);
static Node *make_null_const(int location);
%}

%%

/*
 * query
 */

stmt:
    single_query semicolon_opt
        {
            /*
             * If there is no transition for the lookahead token and the
             * clauses can be reduced to single_query, the parsing is
             * considered successful although it actually isn't.
             *
             * For example, when `MATCH ... CREATE ... MATCH ... ;` query is
             * being parsed, there is no transition for the second `MATCH ...`
             * because the query is wrong but `MATCH .. CREATE ...` is correct
             * so it will be reduced to query_part_last anyway even if there
             * are more tokens to read.
             *
             * Throw syntax error in this case.
             */
            if (yychar != YYEOF)
                yyerror(&yylloc, scanner, extra, "syntax error");

            extra->result = $1;
        }
    ;

semicolon_opt:
    /* empty */
    | ';'
    ;

/*
 * The overall structure of single_query looks like below.
 *
 * ( reading_clause* updating_clause* with )*
 * reading_clause* ( updating_clause+ | updating_clause* return )
 */
single_query:
    query_part_init query_part_last
        {
            $$ = list_concat($1, $2);
        }
    ;

query_part_init:
    /* empty */
        {
            $$ = NIL;
        }
    | query_part_init reading_clause_list updating_clause_list_0 with
        {
            $$ = lappend(list_concat(list_concat($1, $2), $3), $4);
        }
    ;

query_part_last:
    reading_clause_list updating_clause_list_1
        {
            $$ = list_concat($1, $2);
        }
    | reading_clause_list updating_clause_list_0 return
        {
            $$ = lappend(list_concat($1, $2), $3);
        }
    ;

reading_clause_list:
    /* empty */
        {
            $$ = NIL;
        }
    | reading_clause_list reading_clause
        {
            $$ = lappend($1, $2);
        }
    ;

reading_clause:
    match
    ;

updating_clause_list_0:
    /* empty */
        {
            $$ = NIL;
        }
    | updating_clause_list_1
    ;

updating_clause_list_1:
    updating_clause
        {
            $$ = list_make1($1);
        }
    | updating_clause_list_1 updating_clause
        {
            $$ = lappend($1, $2);
        }
    ;

updating_clause:
    create
    | set
    | remove
    | delete
    ;

/*
 * RETURN and WITH clause
 */

return:
    RETURN distinct_opt return_item_list order_by_opt skip_opt limit_opt
        {
            cypher_return *n;

            n = make_ag_node(cypher_return);
            n->distinct = $2;
            n->items = $3;
            n->order_by = $4;
            n->skip = $5;
            n->limit = $6;

            $$ = (Node *)n;
        }
    ;

distinct_opt:
    /* empty */
        {
            $$ = false;
        }
    | DISTINCT
        {
            $$ = true;
        }
    ;

return_item_list:
    return_item
        {
            $$ = list_make1($1);
        }
    | return_item_list ',' return_item
        {
            $$ = lappend($1, $3);
        }
    ;

return_item:
    expr AS var_name
        {
            ResTarget *n;

            n = makeNode(ResTarget);
            n->name = $3;
            n->indirection = NIL;
            n->val = $1;
            n->location = @1;

            $$ = (Node *)n;
        }
    | expr
        {
            ResTarget *n;

            n = makeNode(ResTarget);
            n->name = NULL;
            n->indirection = NIL;
            n->val = $1;
            n->location = @1;

            $$ = (Node *)n;
        }
    ;

order_by_opt:
    /* empty */
        {
            $$ = NIL;
        }
    | ORDER BY sort_item_list
        {
            $$ = $3;
        }
    ;

sort_item_list:
    sort_item
        {
            $$ = list_make1($1);
        }
    | sort_item_list ',' sort_item
        {
            $$ = lappend($1, $3);
        }
    ;

sort_item:
    expr order_opt
        {
            SortBy *n;

            n = makeNode(SortBy);
            n->node = $1;
            n->sortby_dir = $2;
            n->sortby_nulls = SORTBY_NULLS_DEFAULT;
            n->useOp = NIL;
            n->location = -1; // no operator

            $$ = (Node *)n;
        }
    ;

order_opt:
    /* empty */
        {
            $$ = SORTBY_DEFAULT; // is the same with SORTBY_ASC
        }
    | ASC
        {
            $$ = SORTBY_ASC;
        }
    | ASCENDING
        {
            $$ = SORTBY_ASC;
        }
    | DESC
        {
            $$ = SORTBY_DESC;
        }
    | DESCENDING
        {
            $$ = SORTBY_DESC;
        }
    ;

skip_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | SKIP expr
        {
            $$ = $2;
        }
    ;

limit_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | LIMIT expr
        {
            $$ = $2;
        }
    ;

with:
    WITH distinct_opt return_item_list order_by_opt skip_opt limit_opt
    where_opt
        {
            ListCell *li;
            cypher_with *n;

            // check expressions are aliased
            foreach (li, $3)
            {
                ResTarget *item = lfirst(li);

                // variable does not have to be aliased
                if (IsA(item->val, ColumnRef) || item->name)
                    continue;

                ereport(ERROR,
                        (errcode(ERRCODE_SYNTAX_ERROR),
                         errmsg("expression item must be aliased"),
                         errhint("Items can be aliased by using AS."),
                         ag_scanner_errposition(item->location, scanner)));
            }

            n = make_ag_node(cypher_with);
            n->distinct = $2;
            n->items = $3;
            n->order_by = $4;
            n->skip = $5;
            n->limit = $6;
            n->where = $7;

            $$ = (Node *)n;
        }
    ;

/*
 * MATCH clause
 */

match:
    MATCH pattern where_opt
        {
            cypher_match *n;

            n = make_ag_node(cypher_match);
            n->pattern = $2;
            n->where = $3;

            $$ = (Node *)n;
        }
    ;

/*
 * CREATE clause
 */

create:
    CREATE pattern
        {
            cypher_create *n;

            n = make_ag_node(cypher_create);
            n->pattern = $2;

            $$ = (Node *)n;
        }
    ;

/*
 * SET and REMOVE clause
 */

set:
    SET set_item_list
        {
            cypher_set *n;

            n = make_ag_node(cypher_set);
            n->items = $2;
            n->is_remove = false;

            $$ = (Node *)n;

            ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                            errmsg("SET clause not implemented"),
                            ag_scanner_errposition(@1, scanner)));
        }
    ;

set_item_list:
    set_item
        {
            $$ = list_make1($1);
        }
    | set_item_list ',' set_item
        {
            $$ = lappend($1, $3);
        }
    ;

set_item:
    expr '=' expr
        {
            cypher_set_item *n;

            n = make_ag_node(cypher_set_item);
            n->prop = $1;
            n->expr = $3;
            n->is_add = false;

            $$ = (Node *)n;
        }
   | expr PLUS_EQ expr
        {
            cypher_set_item *n;

            n = make_ag_node(cypher_set_item);
            n->prop = $1;
            n->expr = $3;
            n->is_add = true;

            $$ = (Node *)n;
        }
    ;

remove:
    REMOVE remove_item_list
        {
            cypher_set *n;

            n = make_ag_node(cypher_set);
            n->items = $2;
            n->is_remove = true;

            $$ = (Node *)n;

            ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                            errmsg("REMOVE clause not implemented"),
                            ag_scanner_errposition(@1, scanner)));
        }
    ;

remove_item_list:
    remove_item
        {
            $$ = list_make1($1);
        }
    | remove_item_list ',' remove_item
        {
            $$ = lappend($1, $3);
        }
    ;

remove_item:
    expr
        {
            cypher_set_item *n;

            n = make_ag_node(cypher_set_item);
            n->prop = $1;
            n->expr = make_null_const(-1);
            n->is_add = false;

            $$ = (Node *)n;
        }
    ;

/*
 * DELETE clause
 */

delete:
    detach_opt DELETE expr_list
        {
            cypher_delete *n;

            n = make_ag_node(cypher_delete);
            n->detach = $1;
            n->exprs = $3;

            $$ = (Node *)n;

            ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                            errmsg("DELETE clause not implemented"),
                            ag_scanner_errposition(@1, scanner)));
        }
    ;

detach_opt:
    DETACH
        {
            $$ = true;
        }
    | /* EMPTY */
        {
            $$ = false;
        }
    ;

/*
 * common
 */

where_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | WHERE expr
        {
            $$ = $2;
        }
    ;

/*
 * pattern
 */

/* pattern is a set of one or more paths */
pattern:
    path
        {
            $$ = list_make1($1);
        }
    | pattern ',' path
        {
            $$ = lappend($1, $3);
        }
    ;

/* path is a series of connected nodes and relationships */
path:
    anonymous_path
    | var_name '=' anonymous_path /* named path */
        {
            ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                            errmsg("named path not implemented"),
                            ag_scanner_errposition(@1, scanner)));
            $$ = NULL;
        }
    ;

anonymous_path:
    simple_path_opt_parens
        {
            cypher_path *n;

            n = make_ag_node(cypher_path);
            n->path = $1;
            n->location = @1;

            $$ = (Node *)n;
        }
    ;

simple_path_opt_parens:
    simple_path
    | '(' simple_path ')'
        {
            $$ = $2;
        }
    ;

simple_path:
    path_node
        {
            $$ = list_make1($1);
        }
    | simple_path path_relationship path_node
        {
            $$ = lappend(lappend($1, $2), $3);
        }
    ;

path_node:
    '(' var_name_opt label_opt properties_opt ')'
        {
            cypher_node *n;

            n = make_ag_node(cypher_node);
            n->name = $2;
            n->label = $3;
            n->props = $4;
            n->location = @1;

            $$ = (Node *)n;
        }
    ;

path_relationship:
    '-' path_relationship_body '-'
        {
            cypher_relationship *n = (cypher_relationship *)$2;

            n->dir = CYPHER_REL_DIR_NONE;

            $$ = $2;
        }
    | '-' path_relationship_body '-' '>'
        {
            cypher_relationship *n = (cypher_relationship *)$2;

            n->dir = CYPHER_REL_DIR_RIGHT;

            $$ = $2;
        }
    | '<' '-' path_relationship_body '-'
        {
            cypher_relationship *n = (cypher_relationship *)$3;

            n->dir = CYPHER_REL_DIR_LEFT;

            $$ = $3;
        }
    ;

path_relationship_body:
    '[' var_name_opt label_opt properties_opt ']'
        {
            cypher_relationship *n;

            n = make_ag_node(cypher_relationship);
            n->name = $2;
            n->label = $3;
            n->props = $4;

            $$ = (Node *)n;
        }
    ;

label_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | ':' label_name
        {
            $$ = $2;
        }
    ;

properties_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | map
    ;

/*
 * expression
 */

expr:
    expr OR expr
        {
            $$ = make_or_expr($1, $3, @2);
        }
    | expr AND expr
        {
            $$ = make_and_expr($1, $3, @2);
        }
    | NOT expr
        {
            $$ = make_not_expr($2, @1);
        }
    | expr '=' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "=", $1, $3, @2);
        }
    | expr NOT_EQ expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "<>", $1, $3, @2);
        }
    | expr '<' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "<", $1, $3, @2);
        }
    | expr LT_EQ expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "<=", $1, $3, @2);
        }
    | expr '>' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, ">", $1, $3, @2);
        }
    | expr GT_EQ expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, ">=", $1, $3, @2);
        }
    | expr '+' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "+", $1, $3, @2);
        }
    | expr '-' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "-", $1, $3, @2);
        }
    | expr '*' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "*", $1, $3, @2);
        }
    | expr '/' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "/", $1, $3, @2);
        }
    | expr '%' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "%", $1, $3, @2);
        }
    | expr '^' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "^", $1, $3, @2);
        }
    | expr IN expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_IN, "=", $1, $3, @2);
        }
    | expr IS NULL_P %prec IS
        {
            NullTest *n;

            n = makeNode(NullTest);
            n->arg = (Expr *)$1;
            n->nulltesttype = IS_NULL;
            n->location = @2;

            $$ = (Node *)n;
        }
    | expr IS NOT NULL_P %prec IS
        {
            NullTest *n;

            n = makeNode(NullTest);
            n->arg = (Expr *)$1;
            n->nulltesttype = IS_NOT_NULL;
            n->location = @2;

            $$ = (Node *)n;
        }
    | '-' expr %prec UNARY_MINUS
        {
            $$ = do_negate($2, @1);
        }
    | expr STARTS WITH expr %prec STARTS
        {
            cypher_string_match *n;

            n = make_ag_node(cypher_string_match);
            n->operation = CSMO_STARTS_WITH;
            n->lhs = $1;
            n->rhs = $4;
            n->location = @2;

            $$ = (Node *)n;
        }
    | expr ENDS WITH expr %prec ENDS
        {
            cypher_string_match *n;

            n = make_ag_node(cypher_string_match);
            n->operation = CSMO_ENDS_WITH;
            n->lhs = $1;
            n->rhs = $4;
            n->location = @2;

            $$ = (Node *)n;
        }
    | expr CONTAINS expr
        {
            cypher_string_match *n;

            n = make_ag_node(cypher_string_match);
            n->operation = CSMO_CONTAINS;
            n->lhs = $1;
            n->rhs = $3;
            n->location = @2;

            $$ = (Node *)n;
        }
    | expr '[' expr ']'
        {
            A_Indices *i;

            i = makeNode(A_Indices);
            i->is_slice = false;
            i->lidx = NULL;
            i->uidx = $3;

            $$ = append_indirection($1, (Node *)i);
        }
    | expr '[' expr_opt DOT_DOT expr_opt ']'
        {
            A_Indices *i;

            i = makeNode(A_Indices);
            i->is_slice = true;
            i->lidx = $3;
            i->uidx = $5;

            $$ = append_indirection($1, (Node *)i);
        }
    | expr '.' property_key_name
        {
            $$ = append_indirection($1, (Node *)makeString($3));
        }
    | atom
    ;

expr_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | expr
    ;

expr_list:
    expr
        {
            $$ = list_make1($1);
        }
    | expr_list ',' expr
        {
            $$ = lappend($1, $3);
        }
    ;

expr_list_opt:
    /* empty */
        {
            $$ = NIL;
        }
    | expr_list
    ;

atom:
    literal
    | PARAMETER
        {
            cypher_param *n;

            n = make_ag_node(cypher_param);
            n->name = $1;
            n->location = @1;

            $$ = (Node *)n;
        }
    | '(' expr ')'
        {
            $$ = $2;
        }
    | var
    ;

literal:
    INTEGER
        {
            $$ = make_int_const($1, @1);
        }
    | DECIMAL
        {
            $$ = make_float_const($1, @1);
        }
    | STRING
        {
            $$ = make_string_const($1, @1);
        }
    | TRUE_P
        {
            $$ = make_bool_const(true, @1);
        }
    | FALSE_P
        {
            $$ = make_bool_const(false, @1);
        }
    | NULL_P
        {
            $$ = make_null_const(@1);
        }
    | map
    | list
    ;

map:
    '{' map_keyval_list_opt '}'
        {
            cypher_map *n;

            n = make_ag_node(cypher_map);
            n->keyvals = $2;

            $$ = (Node *)n;
        }
    ;

map_keyval_list_opt:
    /* empty */
        {
            $$ = NIL;
        }
    | map_keyval_list
    ;

map_keyval_list:
    property_key_name ':' expr
        {
            $$ = list_make2(makeString($1), $3);
        }
    | map_keyval_list ',' property_key_name ':' expr
        {
            $$ = lappend(lappend($1, makeString($3)), $5);
        }
    ;

list:
    '[' expr_list_opt ']'
        {
            cypher_list *n;

            n = make_ag_node(cypher_list);
            n->elems = $2;

            $$ = (Node *)n;
        }
    ;

var:
    var_name
        {
            ColumnRef *n;

            n = makeNode(ColumnRef);
            n->fields = list_make1(makeString($1));
            n->location = @1;

            $$ = (Node *)n;
        }
    ;

/*
 * names
 */

property_key_name:
    schema_name
    ;

var_name:
    symbolic_name
    ;

var_name_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | var_name
    ;

label_name:
    schema_name
    ;

symbolic_name:
    IDENTIFIER
    ;

schema_name:
    symbolic_name
    | reserved_keyword
        {
            $$ = pstrdup($1);
        }
    ;

reserved_keyword:
    AND
    | AS
    | ASC
    | ASCENDING
    | BY
    | CONTAINS
    | CREATE
    | DELETE
    | DESC
    | DESCENDING
    | DETACH
    | DISTINCT
    | ENDS
    | FALSE_P
    | IN
    | IS
    | LIMIT
    | MATCH
    | NOT
    | NULL_P
    | OR
    | ORDER
    | REMOVE
    | RETURN
    | SET
    | SKIP
    | STARTS
    | TRUE_P
    | WHERE
    | WITH
    ;

%%

/*
 * logical operators
 */

static Node *make_or_expr(Node *lexpr, Node *rexpr, int location)
{
    // flatten "a OR b OR c ..." to a single BoolExpr on sight
    if (IsA(lexpr, BoolExpr))
    {
        BoolExpr *bexpr = (BoolExpr *)lexpr;

        if (bexpr->boolop == OR_EXPR)
        {
            bexpr->args = lappend(bexpr->args, rexpr);

            return (Node *)bexpr;
        }
    }

    return (Node *)makeBoolExpr(OR_EXPR, list_make2(lexpr, rexpr), location);
}

static Node *make_and_expr(Node *lexpr, Node *rexpr, int location)
{
    // flatten "a AND b AND c ..." to a single BoolExpr on sight
    if (IsA(lexpr, BoolExpr))
    {
        BoolExpr *bexpr = (BoolExpr *)lexpr;

        if (bexpr->boolop == AND_EXPR)
        {
            bexpr->args = lappend(bexpr->args, rexpr);

            return (Node *)bexpr;
        }
    }

    return (Node *)makeBoolExpr(AND_EXPR, list_make2(lexpr, rexpr), location);
}

static Node *make_not_expr(Node *expr, int location)
{
    return (Node *)makeBoolExpr(NOT_EXPR, list_make1(expr), location);
}

/*
 * arithmetic operators
 */

static Node *do_negate(Node *n, int location)
{
    if (IsA(n, A_Const))
    {
        A_Const *c = (A_Const *)n;

        // report the constant's location as that of the '-' sign
        c->location = location;

        if (c->val.type == T_Integer)
        {
            c->val.val.ival = -c->val.val.ival;
            return n;
        }
        else if (c->val.type == T_Float)
        {
            do_negate_float(&c->val);
            return n;
        }
    }

    return (Node *)makeSimpleA_Expr(AEXPR_OP, "-", NULL, n, location);
}

static void do_negate_float(Value *v)
{
    Assert(IsA(v, Float));

    if (v->val.str[0] == '-')
        v->val.str = v->val.str + 1; // just strip the '-'
    else
        v->val.str = psprintf("-%s", v->val.str);
}

/*
 * indirection
 */

static Node *append_indirection(Node *expr, Node *selector)
{
    A_Indirection *indir;

    if (IsA(expr, A_Indirection))
    {
        indir = (A_Indirection *)expr;
        indir->indirection = lappend(indir->indirection, selector);

        return expr;
    }
    else
    {
        indir = makeNode(A_Indirection);
        indir->arg = expr;
        indir->indirection = list_make1(selector);

        return (Node *)indir;
    }
}

/*
 * literals
 */

static Node *make_int_const(int i, int location)
{
    A_Const *n;

    n = makeNode(A_Const);
    n->val.type = T_Integer;
    n->val.val.ival = i;
    n->location = location;

    return (Node *)n;
}

static Node *make_float_const(char *s, int location)
{
    A_Const *n;

    n = makeNode(A_Const);
    n->val.type = T_Float;
    n->val.val.str = s;
    n->location = location;

    return (Node *)n;
}

static Node *make_string_const(char *s, int location)
{
    A_Const *n;

    n = makeNode(A_Const);
    n->val.type = T_String;
    n->val.val.str = s;
    n->location = location;

    return (Node *)n;
}

static Node *make_bool_const(bool b, int location)
{
    cypher_bool_const *n;

    n = make_ag_node(cypher_bool_const);
    n->boolean = b;
    n->location = location;

    return (Node *)n;
}

static Node *make_null_const(int location)
{
    A_Const *n;

    n = makeNode(A_Const);
    n->val.type = T_Null;
    n->location = location;

    return (Node *)n;
}
