/* $Id: informix.ec,v 1.16 2006/03/26 16:56:49 santana Exp $ */
/*
* Copyright (c) 2006, Gerardo Santana Gomez Garrido <gerardo.santana@gmail.com>
* All rights reserved.
* 
* Redistribution and use in source and binary forms, with or without
* modification, are permitted provided that the following conditions
* are met:
* 
* 1. Redistributions of source code must retain the above copyright
*    notice, this list of conditions and the following disclaimer.
* 2. Redistributions in binary form must reproduce the above copyright
*    notice, this list of conditions and the following disclaimer in the
*    documentation and/or other materials provided with the distribution.
* 3. The name of the author may not be used to endorse or promote products
*    derived from this software without specific prior written permission.
* 
* THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
* IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
* WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
* DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
* INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
* (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
* SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
* HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
* STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
* ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
* POSSIBILITY OF SUCH DAMAGE.
*/

#include "ruby.h"

#define NDEBUG
#include <assert.h> /* XXX */
#include <sqlstype.h>
#include <sqltypes.h>

static VALUE rb_cDate;

static VALUE rb_mInformix;
static VALUE rb_mSequentialCursor;
static VALUE rb_mScrollCursor;
static VALUE rb_mInsertCursor;

static VALUE rb_cDatabase;
static VALUE rb_cStatement;
static VALUE rb_cCursor;

static ID s_read, s_new, s_utc, s_day, s_month, s_year;
static ID s_hour, s_min, s_sec, s_usec;
static VALUE sym_name, sym_type, sym_nullable, sym_stype, sym_length;
static VALUE sym_precision, sym_scale, sym_default;
static VALUE sym_scroll, sym_hold;

EXEC SQL begin declare section;
typedef struct {
	short is_select;
	struct sqlda daInput, *daOutput;
	short *indInput, *indOutput;
	char *bfOutput;
	char nmCursor[30];
	char nmStmt[30];
} cursor_t;
EXEC SQL end   declare section;

/* Helper functions ------------------------------------------------------- */

/*
 * Counts the number of markers '?' in the query
 */
static int count_markers(const char *query)
{
	register char c, quote = 0;
	register int count = 0;

	while(c = *query++) {
		if (quote && c != quote)
			;
		else if (quote == c) {
			quote = 0;
		}
		else if (c == '\'' || c == '"') {
			quote = c;
		}
		else if (c == '?') {
			++count;
		}
	}
	return count;
}

/*
 * Allocates memory for the indicators array and slots for the input
 * parameters, if any. Freed by free_input_slots.
 */
static void
alloc_input_slots(cursor_t *c, const char *query)
{
	register int n;

	n = count_markers(query);
	c->daInput.sqld = n;
	if (n) {
		c->daInput.sqlvar = ALLOC_N(struct sqlvar_struct, n);
		assert(c->daInput.sqlvar != NULL);
		c->indInput = ALLOC_N(short, n);
		assert(c->indInput != NULL);
		while(n--)
			c->daInput.sqlvar[n].sqlind = &c->indInput[n];
	}
	else {
		c->daInput.sqlvar = NULL;
		c->indInput = NULL;
	}
}

/*
 * Allocates memory for the output data slots and its indicators array.
 * Freed by free_output_slots.
 */
static void
alloc_output_slots(cursor_t *c)
{
	register int i, count;
	register short *ind;
	struct sqlvar_struct *var;
	register char *buffer;

	ind = c->indOutput = ALLOC_N(short, c->daOutput->sqld);
	assert(c->indOutput != NULL);

	var = c->daOutput->sqlvar;
	for (i = count = 0; i < c->daOutput->sqld; i++, ind++, var++) {
		var->sqlind = ind;
		var->sqllen = rtypmsize(var->sqltype, var->sqllen);
		count = rtypalign(count, var->sqltype) + var->sqllen;
	}

	buffer = c->bfOutput = ALLOC_N(char, count);
	assert(buffer != NULL);

	var = c->daOutput->sqlvar;
	for (i = 0; i < c->daOutput->sqld; i++, var++) {
		buffer = (char *)rtypalign((mint)buffer, var->sqltype);
		if ((var->sqltype&0xFF) == SQLBYTES || (var->sqltype&0xFF) == SQLTEXT) {
			loc_t *p;
			p = (loc_t *)buffer;
			byfill(p, sizeof(loc_t), 0);
			p->loc_loctype = LOCMEMORY;
			p->loc_bufsize = -1;
		}
		var->sqldata = buffer;
		buffer += var->sqllen;
		if (var->sqltype == SQLDTIME) {
			var->sqllen = 0;
		}
	}
}

/*
 * Frees the allocated memory of the input parameters, but not the slots
 * nor the indicators array. Allocated by bind_input_params.
 */
static void
clean_input_slots(cursor_t *c)
{
	register int count;
	register struct sqlvar_struct *var;

	if (c->daInput.sqlvar == NULL)
		return;
	var = c->daInput.sqlvar;
	count = c->daInput.sqld;
	while(count--) {
		if (var->sqldata != NULL) {
			if (var->sqltype == CLOCATORTYPE) {
				loc_t *p = (loc_t *)var->sqldata;
				if (p->loc_buffer != NULL) {
					free(p->loc_buffer);
				}
			}
			free(var->sqldata);
			var->sqldata = NULL;
			var++;
		}
	}
}

/*
 * Frees the memory for the input parameters, their slots, and the indicators
 * array. Allocated by alloc_input_slots and bind_input_params.
 */
static void
free_input_slots(cursor_t *c)
{
	clean_input_slots(c);
	if (c->daInput.sqlvar) {
		free(c->daInput.sqlvar);
		c->daInput.sqlvar = NULL;
		c->daInput.sqld = 0;
	}
	if (c->indInput) {
		free(c->indInput);
		c->indInput = NULL;
	}
}

static void
free_output_slots(cursor_t *c)
{
	if (c->daOutput != NULL) {
		struct sqlvar_struct *var = c->daOutput->sqlvar;
		if (var) {
			int i;
			for (i = 0; i < c->daOutput->sqld; i++, var++) {
				if ((var->sqltype&0xFF) == SQLBYTES ||
					(var->sqltype&0xFF) == SQLTEXT) {
					loc_t *p = (loc_t *) var->sqldata;
					if(p -> loc_buffer)
						free(p->loc_buffer);
				}
			}
		}
		free(c->daOutput);
		c->daOutput = NULL;
	}
	if (c->indOutput != NULL) {
		free(c->indOutput);
		c->indOutput = NULL;
	}
	if (c->bfOutput != NULL) {
		free(c->bfOutput);
		c->bfOutput = NULL;
	}
}

static void
bind_input_params(cursor_t *c, VALUE *argv)
{
	VALUE data, klass;
	register int i;
	register struct sqlvar_struct *var;

	var = c->daInput.sqlvar;
	for (i = 0; i < c->daInput.sqld; i++, var++) {
		data = argv[i];

		switch(TYPE(data)) {
		case T_NIL:
			var->sqltype = CSTRINGTYPE;
			var->sqldata = NULL;
			var->sqllen = 0;
			*var->sqlind = -1;
			break;
		case T_FIXNUM:
			var->sqldata = (char *)ALLOC(long);
			assert(var->sqldata != NULL);
			*((long *)var->sqldata) = FIX2LONG(data);
			var->sqltype = CLONGTYPE;
			var->sqllen = sizeof(long);
			*var->sqlind = 0;
			break;
		case T_FLOAT:
			var->sqldata = (char *)ALLOC(double);
			assert(var->sqldata != NULL);
			*((double *)var->sqldata) = NUM2DBL(data);
			var->sqltype = CDOUBLETYPE;
			var->sqllen = sizeof(double);
			*var->sqlind = 0;
			break;
		case T_TRUE:
		case T_FALSE:
			var->sqldata = ALLOC(char);
			assert(var->sqldata != NULL);
			*var->sqldata = TYPE(data) == T_TRUE? 't': 'f';
			var->sqltype = CCHARTYPE;
			var->sqllen = sizeof(char);
			*var->sqlind = 0;
			break;
		default:
			klass = rb_obj_class(data);
			if (klass == rb_cDate) {
				int2 mdy[3];
				int4 date;

				mdy[0] = FIX2INT(rb_funcall(data, s_month, 0));
				mdy[1] = FIX2INT(rb_funcall(data, s_day, 0));
				mdy[2] = FIX2INT(rb_funcall(data, s_year, 0));
				rmdyjul(mdy, &date);

				var->sqldata = (char *)ALLOC(int4);
				assert(var->sqldata != NULL);
				*((int4 *)var->sqldata) = date;
				var->sqltype = CDATETYPE;
				var->sqllen = sizeof(int4);
				*var->sqlind = 0;
				break;
			}
			if (klass == rb_cTime) {
				char buffer[30];
				short year, month, day, hour, minute, second;
				int usec;
				dtime_t *dt;

				year = FIX2INT(rb_funcall(data, s_year, 0));
				month = FIX2INT(rb_funcall(data, s_month, 0));
				day = FIX2INT(rb_funcall(data, s_day, 0));
				hour = FIX2INT(rb_funcall(data, s_hour, 0));
				minute = FIX2INT(rb_funcall(data, s_min, 0));
				second = FIX2INT(rb_funcall(data, s_sec, 0));
				usec = FIX2INT(rb_funcall(data, s_usec, 0));

				dt = ALLOC(dtime_t);
				assert(dt != NULL);

				dt->dt_qual = TU_DTENCODE(TU_YEAR, TU_F5);
				snprintf(buffer, sizeof(buffer), "%d-%d-%d %d:%d:%d.%d",
					year, month, day, hour, minute, second, usec/10);
				dtcvasc(buffer, dt);

				var->sqldata = (char *)dt;
				var->sqltype = CDTIMETYPE;
				var->sqllen = sizeof(dtime_t);
				*var->sqlind = 0;
				break;
			}
			if (rb_respond_to(data, s_read)) {
				char *str;
				loc_t *loc;
				long len;

				data = rb_funcall(data, s_read, 0);
				data = StringValue(data);
				str = RSTRING(data)->ptr;
				len = RSTRING(data)->len;

				loc = (loc_t *)ALLOC(loc_t);
				assert(loc != NULL);
				byfill(loc, sizeof(loc_t), 0);
				loc->loc_loctype = LOCMEMORY;
				loc->loc_buffer = (char *)ALLOC_N(char, len);
				assert(loc->loc_buffer != NULL);
				memcpy(loc->loc_buffer, str, len);
				loc->loc_bufsize = loc->loc_size = len;

				var->sqldata = (char *)loc;
				var->sqltype = CLOCATORTYPE;
				var->sqllen = sizeof(loc_t);
				*var->sqlind = 0;
				break;
			}
			{
			VALUE str;
			str = rb_check_string_type(data);
			if (NIL_P(str)) {
				data = rb_obj_as_string(data);
			}
			else {
				data = str;
			}
			}
		case T_STRING: {
			char *str;
			long len;

			str = RSTRING(data)->ptr;
			len = RSTRING(data)->len;
			var->sqldata = ALLOC_N(char, len + 1);
			assert(var->sqldata != NULL);
			memcpy(var->sqldata, str, len);
			var->sqldata[len] = 0;
			var->sqltype = CSTRINGTYPE;
			var->sqllen = len;
			*var->sqlind = 0;
			break;
		}
		}
	}
}

static VALUE
make_result(VALUE self, VALUE type)
{
	VALUE item, record, field_names;
	cursor_t *c;
	register int i;
	register struct sqlvar_struct *var;

	Data_Get_Struct(self, cursor_t, c);

	if(type == T_ARRAY)
		record = rb_ary_new2(c->daOutput->sqld);
	else {
		/* XXX use a C array instead */
		field_names = rb_iv_get(self, "@field_names");
		record = rb_hash_new();
	}

	var = c->daOutput->sqlvar;
	for (i = 0; i < c->daOutput->sqld; i++, var++) {
		if (*var->sqlind == -1) {
			item = Qnil;
		} else {
		switch(var->sqltype) {
		case SQLCHAR:
		case SQLVCHAR:
		case SQLNCHAR:
		case SQLNVCHAR:
			item = rb_str_new2(var->sqldata);
			break;
		case SQLSMINT:
			item = INT2FIX(*(short *)var->sqldata);
			break;
		case SQLINT:
		case SQLSERIAL:
			item = INT2FIX(*(int *)var->sqldata);
			break;
		case SQLINT8:
		case SQLSERIAL8:
			item = LONG2FIX(*(long *)var->sqldata);
			break;
		case SQLSMFLOAT:
			item = rb_float_new(*(float *)var->sqldata);
			break;
		case SQLFLOAT:
			item = rb_float_new(*(double *)var->sqldata);
			break;
		case SQLDATE: {
			VALUE year, month, day;
			int2 mdy[3];

			rjulmdy(*(int4 *)var->sqldata, mdy);
			year = INT2FIX(mdy[2]);
			month = INT2FIX(mdy[0]);
			day = INT2FIX(mdy[1]);
			item = rb_funcall(rb_cDate, s_new, 3, year, month, day);
			break;
		}
		case SQLDTIME: {
			register short qual;
			short year, month, day, hour, minute, second;
			int usec;
			dtime_t *dt;
			register char *dgts;

			month = day = 1;
			year = hour = minute = second = usec = 0;
			dt = (dtime_t *)var->sqldata;
			dgts = dt->dt_dec.dec_dgts;
			qual = TU_START(dt->dt_qual);
			for (; qual <= TU_END(dt->dt_qual); qual++) {
				switch(qual) {
				case TU_YEAR:
					year = 100**dgts++ + *dgts++;
					break;
				case TU_MONTH:
					month = *dgts++;
					break;
				case TU_DAY:
					day = *dgts++;
					break;
				case TU_HOUR:
					hour = *dgts++;
					break;
				case TU_MINUTE:
					minute = *dgts++;
					break;
				case TU_SECOND:
					second = *dgts++;
					break;
				case TU_F1:
					usec = 10000**dgts++;
					break;
				case TU_F3:
					usec += 100**dgts++;
					break;
				case TU_F5:
					usec += *dgts++;
					break;
				}
			}

			item = rb_funcall(rb_cTime, s_utc, 7,
				INT2FIX(year), INT2FIX(month), INT2FIX(day),
				INT2FIX(hour), INT2FIX(minute), INT2FIX(second),
				INT2FIX(usec));
			break;
		}
		case SQLDECIMAL:
		case SQLMONEY: {
			double dblValue;
			dectodbl((dec_t *)var->sqldata, &dblValue);
			item = rb_float_new(dblValue);
			break;
		}
		case SQLBOOL:
			item = var->sqldata[0] == 't'? Qtrue: Qfalse;
			break;
		case SQLBYTES:
		case SQLTEXT: {
			loc_t *loc;
			loc = (loc_t *)var->sqldata;
			item = rb_str_new(loc->loc_buffer, loc->loc_size);
			break;
		}
		case SQLSET:
		case SQLMULTISET:
		case SQLLIST:
		case SQLROW:
		case SQLCOLLECTION:
		case SQLROWREF:
		case SQLUDTVAR:
		case SQLUDTFIXED:
		case SQLREFSER8:
		case SQLLVARCHAR:
		case SQLSENDRECV:
		case SQLIMPEXP:
		case SQLIMPEXPBIN:
		case SQLUNKNOWN:
		default:
			item = Qnil;
			break;
		}
		}
		if (type == T_ARRAY) {
			rb_ary_store(record, i, item);
		} else {
			/* XXX use a C array instead */
			rb_hash_aset(record, rb_ary_entry(field_names, i), item);
		}
	}
	return record;
}

static void
get_column_info(VALUE self, struct sqlda *d)
{
	register int i, count;
	VALUE ary;

	count = d->sqld;
	/* XXX use a C array instead, in a C struct */
	ary = rb_ary_new2(count);
	rb_iv_set(self, "@field_names", ary);
	for(i = 0; i < count; i++) {
		rb_ary_store(ary, i, rb_str_new2(d->sqlvar[i].sqlname));
	}
}


/* module Informix -------------------------------------------------------- */

static VALUE
informix_connect(int argc, VALUE *argv, VALUE self)
{
	return rb_class_new_instance(argc, argv, rb_cDatabase);
}


/* class Database --------------------------------------------------------- */

static VALUE
database_open(int argc, VALUE *argv, VALUE self)
{
	VALUE str, arg[3];

	EXEC SQL begin declare section;
		char *db, *user = NULL, *pass = NULL, conn[30];
	EXEC SQL end   declare section;

	rb_scan_args(argc, argv, "12", &arg[0], &arg[1], &arg[2]);

	if (NIL_P(arg[0])) {
		rb_raise(rb_eRuntimeError, "Database name must be specified");
	}

	str  = StringValue(arg[0]);
	db = RSTRING(str)->ptr;
	rb_iv_set(self, "@name", arg[0]);

	snprintf(conn, sizeof(conn), "CONN%p", self);
	rb_iv_set(self, "@connection", rb_str_new2(conn));

	if (!NIL_P(arg[1])) {
		str  = StringValue(arg[1]);
		user = RSTRING(str)->ptr;
	}

	if (!NIL_P(arg[2])) {
		str  = StringValue(arg[2]);
		user = RSTRING(str)->ptr;
	}

	if (user && pass) {
		EXEC SQL connect to :db as :conn user :user
			using :pass with concurrent transaction;
	}
	else {
		EXEC SQL connect to :db as :conn with concurrent transaction;
	}
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}

	return self;
}

static VALUE
database_close(VALUE self)
{
	VALUE str;
	EXEC SQL begin declare section;
		char *c_str;
	EXEC SQL end   declare section;

	str = rb_iv_get(self, "@connection");
	str = StringValue(str);
	c_str = RSTRING(str)->ptr;

	EXEC SQL disconnect :c_str;

	return self;
}

static VALUE
database_immediate(VALUE self, VALUE arg)
{
	EXEC SQL begin declare section;
		char *query;
	EXEC SQL end   declare section;

	arg  = StringValue(arg);
	query = RSTRING(arg)->ptr;

	EXEC SQL execute immediate :query;
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}

	return INT2FIX(sqlca.sqlerrd[2]);
}

static VALUE
database_initialize(int argc, VALUE *argv, VALUE self)
{
	return database_open(argc, argv, self);
}

static VALUE
database_rollback(VALUE self)
{
	EXEC SQL rollback;
	return self;
}

static VALUE
database_commit(VALUE self)
{
	EXEC SQL commit;
	return self;
}

static VALUE
database_transfail(VALUE self)
{
	database_rollback(self);
	return Qundef;
}

static VALUE
database_transaction(VALUE self)
{
	VALUE ret;

	EXEC SQL commit;

	EXEC SQL begin work;
	ret = rb_rescue(rb_yield, self, database_transfail, self);
	if (ret == Qundef) {
		rb_raise(rb_eRuntimeError, "Transaction rolled back");
	}
	EXEC SQL commit;
	return ret;
}

static VALUE
database_prepare(VALUE self, VALUE query)
{
	VALUE argv[] = { self, query };
	return rb_class_new_instance(2, argv, rb_cStatement);
}

static VALUE
database_cursor(int argc, VALUE *argv, VALUE self)
{
	VALUE arg[3];

	arg[0] = self;
	rb_scan_args(argc, argv, "11", &arg[1], &arg[2]);
	return rb_class_new_instance(3, arg, rb_cCursor);
}

/*
 * Obtains information for every column for the table given.
 * IBM Informix Guide to SQL: Reference (syscolumns)
 */
static VALUE
database_columns(VALUE self, VALUE table)
{
	VALUE v, column, result;
	char *stype;
	static char *stypes[] = {
		"CHAR", "SMALLINT", "INTEGER", "FLOAT", "SMALLFLOAT", "DECIMAL",
		"SERIAL", "DATE", "MONEY", "NULL", "DATETIME", "BYTE",
		"TEXT", "VARCHAR", "INTERVAL", "NCHAR", "NVARCHAR", "INT8",
		"SERIAL8", "SET", "MULTISET", "LIST", "UNNAMED ROW", "NAMED ROW",
		"VARIABLE-LENGTH OPAQUE TYPE"
	};

	static char *qualifiers[] = {
		"YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND"
	};

	EXEC SQL begin declare section;
		char *tabname;
		int tabid;
		varchar colname[129];
		short coltype, collength;
		char deftype[2];
		varchar defvalue[257];
	EXEC SQL end   declare section;

	table = StringValue(table);
	tabname = RSTRING(table)->ptr;

	EXEC SQL select tabid into :tabid from systables where tabname = :tabname;

	if (sqlca.sqlcode == 100) {
		rb_raise(rb_eRuntimeError, "Table '%s' doesn't exist", tabname);
	}

	result = rb_ary_new();

	EXEC SQL declare cur cursor for
		select colname, coltype, collength, type, default, c.colno
		from syscolumns c, outer sysdefaults d
		where c.tabid = :tabid and c.tabid = d.tabid and c.colno = d.colno
		order by c.colno;

	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}
	EXEC SQL open cur;
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}

	for(;;) {
		EXEC SQL fetch cur into :colname, :coltype, :collength,
			:deftype, :defvalue;
		if (sqlca.sqlcode < 0) {
			rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
		}
		if (sqlca.sqlcode == 100) {
			break;
		}
		column = rb_hash_new();
		rb_hash_aset(column, sym_name, rb_str_new2(colname));
		rb_hash_aset(column, sym_type, INT2FIX(coltype));
		rb_hash_aset(column, sym_nullable, coltype&0x100? Qfalse: Qtrue);

		if ((coltype&0xFF) < 23) {
			stype = coltype == 4118? stypes[23]: stypes[coltype&0xFF];
		}
		else {
			stype = stypes[24];
		}
		rb_hash_aset(column, sym_stype, rb_str_new2(stype));
		rb_hash_aset(column, sym_length, INT2FIX(collength));

		switch(coltype&0xFF) {
		case SQLVCHAR:
		case SQLNVCHAR:
		case SQLMONEY:
		case SQLDECIMAL:
			rb_hash_aset(column, sym_precision, INT2FIX(collength >> 8));
			rb_hash_aset(column, sym_scale, INT2FIX(collength&0xFF));
			break;
		case SQLDATE:
		case SQLDTIME:
		case SQLINTERVAL:
			rb_hash_aset(column, sym_length, INT2FIX(collength >> 8));
			rb_hash_aset(column, sym_precision, INT2FIX((collength&0xF0) >> 4));
			rb_hash_aset(column, sym_scale, INT2FIX(collength&0xF));
			break;
		default:
			rb_hash_aset(column, sym_precision, INT2FIX(0));
			rb_hash_aset(column, sym_scale, INT2FIX(0));
		}

		if (!deftype[0]) {
			v = Qnil;
		}
		else {
			switch(deftype[0]) {
			case 'C': {
				char current[28];
				snprintf(current, sizeof(current), "CURRENT %s TO %s",
					qualifiers[(collength&0xF0) >> 5],
					qualifiers[(collength&0xF)>>1]);
				v = rb_str_new2(current);
				break;
			}
			case 'L':
				switch (coltype & 0xFF) {
				case SQLCHAR:
				case SQLNCHAR:
				case SQLVCHAR:
				case SQLNVCHAR:
					v = rb_str_new2(defvalue);
					break;
				default: {
					char *s = defvalue;
					while(*s++ != ' ');
					if ((coltype&0xFF) == SQLFLOAT ||
						(coltype&0xFF) == SQLSMFLOAT ||
						(coltype&0xFF) == SQLMONEY ||
						(coltype&0xFF) == SQLDECIMAL)
						v = rb_float_new(atof(s));
					else
						v = LONG2FIX(atol(s));
				}
				}
				break;
			case 'N':
				v = rb_str_new2("NULL");
				break;
			case 'T':
				v = rb_str_new2("today");
				break;
			case 'U':
				v = rb_str_new2("user");
				break;
			case 'S':
			default: /* XXX */
				v = Qnil;
			}
		}
		rb_hash_aset(column, sym_default, v);
		rb_ary_push(result, column);
	}

	EXEC SQL close cur;
	EXEC SQL free cur;

	return result;
}

/* class Statement ------------------------------------------------------- */

static void
statement_free(void *p)
{
	EXEC SQL begin declare section;
		cursor_t *c;
	EXEC SQL end   declare section;

	c = p;
	free_input_slots(c);
	free_output_slots(c);
	EXEC SQL free :c->nmStmt;
	free(c);
}

static VALUE
statement_alloc(VALUE klass)
{
	cursor_t *c;

	c = ALLOC(cursor_t);
	assert(c != NULL);
	c->daInput.sqlvar = NULL;
	c->daOutput = NULL;
	c->indInput = NULL;
	c->indOutput = NULL;
	c->bfOutput = NULL;
	return Data_Wrap_Struct(klass, 0, statement_free, c);
}

static VALUE
statement_initialize(VALUE self, VALUE db, VALUE query)
{
	struct sqlda *output;
	EXEC SQL begin declare section;
		char *c_query;
		cursor_t *c;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	output = c->daOutput;

	snprintf(c->nmStmt, sizeof(c->nmStmt), "STMT%p", self);

	rb_iv_set(self, "@db", db);
	query = StringValue(query);
	c_query = RSTRING(query)->ptr;

	alloc_input_slots(c, c_query);

	EXEC SQL prepare :c->nmStmt from :c_query;
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}
	EXEC SQL describe :c->nmStmt into output;
	c->daOutput = output;

	c->is_select = (sqlca.sqlcode == 0 || sqlca.sqlcode == SQ_EXECPROC);

	if (c->is_select) {
		alloc_output_slots(c);
		get_column_info(self, output);
	}
	else {
		free(c->daOutput);
		c->daOutput = NULL;
	}
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}
	return self;
}


/*
 * Executes the previously prepared statement in statement_initialize, 
 * binding the input parameters and cleaning them afterwards, if needed.
 * Returns the record retrieved, in the case of a singleton select, or the
 * number of rows affected, in the case of any other statement.
 */
static VALUE
statement_call(int argc, VALUE *argv, VALUE self)
{
	struct sqlda *input, *output;
	EXEC SQL begin declare section;
		cursor_t *c;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	output = c->daOutput;
	input = &c->daInput;

	if (argc != input->sqld) {
		rb_raise(rb_eRuntimeError, "Wrong number of parameters (%d for %d)",
			argc, input->sqld);
	}


	if (c->is_select) {
		if (argc) {
			bind_input_params(c, argv);
			EXEC SQL execute :c->nmStmt into descriptor output
				using descriptor input;
			clean_input_slots(c);
		}
		else {
			EXEC SQL execute :c->nmStmt into descriptor output;
		}
		if (sqlca.sqlcode < 0) {
			rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
		}
		return sqlca.sqlcode == 100 ? Qnil: make_result(self, T_HASH);
	}
	else {
		if (argc)  {
			bind_input_params(c, argv);
			EXEC SQL execute :c->nmStmt using descriptor input;
			clean_input_slots(c);
		}
		else
			EXEC SQL execute :c->nmStmt;
	}
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}
	return INT2FIX(sqlca.sqlerrd[2]);
}

static VALUE
statement_drop(VALUE self)
{
	EXEC SQL begin declare section;
		cursor_t *c;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	free_input_slots(c);
	free_output_slots(c);
	EXEC SQL free :c->nmStmt;
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}
	return Qnil;
}


/* module SequentialCursor ----------------------------------------------- */

static VALUE
fetch(VALUE self, VALUE type)
{
	struct sqlda *output;
	EXEC SQL begin declare section;
		cursor_t *c;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	output = c->daOutput;

	EXEC SQL fetch :c->nmCursor using descriptor output;
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}
	return sqlca.sqlcode == 100 ? Qnil: make_result(self, type);
}

static VALUE
seqcur_fetch(VALUE self)
{
	return fetch(self, T_ARRAY);
}

static VALUE
seqcur_fetch_hash(VALUE self)
{
	return fetch(self, T_HASH);
}

static VALUE
seqcur_fetch_many(VALUE self, VALUE n)
{
	VALUE row, rows;
	int i, max, all = n == Qnil;

	if (!all) {
		max = FIX2INT(n);
	}

	rows = rb_ary_new();
	for(i = 0; all || i < max; i++) {
		row = fetch(self, T_ARRAY);
		if (row == Qnil) {
			break;
		}
		rb_ary_push(rows, row);
	}
	return i == 0? Qnil: rows;
}

static VALUE
seqcur_fetch_all(VALUE self)
{
	return seqcur_fetch_many(self, Qnil);
}

/* module InsertCursor --------------------------------------------------- */

static VALUE
inscur_put(int argc, VALUE *argv, VALUE self)
{
	struct sqlda *input;
	EXEC SQL begin declare section;
		cursor_t *c;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	input = &c->daInput;

	bind_input_params(c, argv);
	if (argc != input->sqld) {
		rb_raise(rb_eRuntimeError, "Wrong number of parameters (%d for %d)",
			argc, input->sqld);
	}
	EXEC SQL put :c->nmCursor using descriptor input;
	clean_input_slots(c);
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "%d:Informix Error: %d",
			__LINE__, sqlca.sqlcode);
	}
	/* XXX 2-448, Guide to SQL: Sytax*/
	return INT2FIX(sqlca.sqlerrd[2]);
}

static VALUE
inscur_flush(VALUE self)
{
	EXEC SQL begin declare section;
		cursor_t *c;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	EXEC SQL flush :c->nmCursor;
	return self;
}


/* class Cursor ---------------------------------------------------------- */

static void
cursor_free(void *p)
{
	EXEC SQL begin declare section;
		cursor_t *c;
	EXEC SQL end   declare section;

	c = p;
	free_input_slots(c);
	free_output_slots(c);
	EXEC SQL close :c->nmCursor;
	EXEC SQL free :c->nmCursor;
	EXEC SQL free :c->nmStmt;
	free(c);
}

static VALUE
cursor_alloc(VALUE klass)
{
	cursor_t *c;

	c = ALLOC(cursor_t);
	assert(c != NULL);
	c->daInput.sqlvar = NULL;
	c->daOutput = NULL;
	c->indInput = NULL;
	c->indOutput = NULL;
	c->bfOutput = NULL;
	return Data_Wrap_Struct(klass, 0, cursor_free, c);
}

static VALUE
cursor_initialize(VALUE self, VALUE db, VALUE query, VALUE options)
{
	VALUE scroll, hold;
	struct sqlda *output;

	EXEC SQL begin declare section;
		char *c_query;
		cursor_t *c;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	scroll = hold = Qfalse;

	snprintf(c->nmCursor, sizeof(c->nmCursor), "CUR%p", self);
	snprintf(c->nmStmt, sizeof(c->nmStmt), "STMT%p", self);

	rb_iv_set(self, "@db", db);
	rb_iv_set(self, "@query", query);

	query = StringValue(query);
	c_query = RSTRING(query)->ptr;

	if (RTEST(options)) {
		scroll = rb_hash_aref(options, sym_scroll);
		hold = rb_hash_aref(options, sym_hold);
	}

	alloc_input_slots(c, c_query);

	EXEC SQL prepare :c->nmStmt from :c_query;
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}

	if (RTEST(scroll) && RTEST(hold)) {
		EXEC SQL declare :c->nmCursor scroll cursor with hold for :c->nmStmt;
	}
	else if (RTEST(hold)) {
		EXEC SQL declare :c->nmCursor cursor with hold for :c->nmStmt;
	}
	else if (RTEST(scroll)) {
		EXEC SQL declare :c->nmCursor scroll cursor for :c->nmStmt;
	}
	else {
		EXEC SQL declare :c->nmCursor cursor for :c->nmStmt;
	}
	if (sqlca.sqlcode < 0) {
		rb_warn("Informix Error: %d\n", sqlca.sqlcode);
		return Qnil;
	}

	EXEC SQL describe :c->nmStmt into output;
	c->daOutput = output;

	c->is_select = (sqlca.sqlcode == 0 || sqlca.sqlcode == SQ_EXECPROC);

	if (c->is_select) {
		alloc_output_slots(c);
		get_column_info(self, c->daOutput);
		rb_extend_object(self, rb_mSequentialCursor);
		if (scroll) {
				rb_extend_object(self, rb_mScrollCursor);
		}
	}
	else {
		free(c->daOutput);
		c->daOutput = NULL;
		rb_extend_object(self, rb_mInsertCursor);
	}
	return self;
}

static VALUE
cursor_open(int argc, VALUE *argv, VALUE self)
{
	struct sqlda *input;
	EXEC SQL begin declare section;
		cursor_t *c;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	input = &c->daInput;

	if (c->is_select) {
		if (argc != input->sqld) {
			rb_raise(rb_eRuntimeError, "Wrong number of parameters (%d for %d)",
				argc, input->sqld);
		}
		if (argc) {
			bind_input_params(c, argv);
			EXEC SQL open :c->nmCursor using descriptor input
				with reoptimization;
			clean_input_slots(c);
		}
		else
			EXEC SQL open :c->nmCursor with reoptimization;
	}
	else {
		EXEC SQL open :c->nmCursor;
	}
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}
	return self;
}

static VALUE
cursor_close(VALUE self)
{
	EXEC SQL begin declare section;
		cursor_t *c;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	clean_input_slots(c);
	EXEC SQL close :c->nmCursor;
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}
	return self;
}

static VALUE
cursor_drop(VALUE self)
{
	EXEC SQL begin declare section;
		cursor_t *c;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	cursor_close(self);
	free_input_slots(c);
	free_output_slots(c);
	EXEC SQL free :c->nmCursor;
	EXEC SQL free :c->nmStmt;
	if (sqlca.sqlcode < 0) {
		rb_raise(rb_eRuntimeError, "Informix Error: %d", sqlca.sqlcode);
	}
	return Qnil;
}

/* Entry point ------------------------------------------------------------ */

void Init_informix(void)
{
	/* module Informix ---------------------------------------------------- */
	rb_mInformix = rb_define_module("Informix");
	rb_mScrollCursor = rb_define_module_under(rb_mInformix, "ScrollCursor");
	rb_mInsertCursor = rb_define_module_under(rb_mInformix, "InsertCursor");
	rb_define_module_function(rb_mInformix, "connect", informix_connect, -1);

	/* class Database ----------------------------------------------------- */
	rb_cDatabase = rb_define_class_under(rb_mInformix, "Database", rb_cObject);
	rb_define_method(rb_cDatabase, "initialize", database_initialize, -1);
	rb_define_method(rb_cDatabase, "open", database_open, -1);
	rb_define_method(rb_cDatabase, "close", database_close, 0);
	rb_define_method(rb_cDatabase, "immediate", database_immediate, 1);
	rb_define_alias(rb_cDatabase, "do", "immediate");
	rb_define_method(rb_cDatabase, "rollback", database_rollback, 0);
	rb_define_method(rb_cDatabase, "commit", database_commit, 0);
	rb_define_method(rb_cDatabase, "transaction", database_transaction, 0);
	rb_define_method(rb_cDatabase, "prepare", database_prepare, 1);
	rb_define_method(rb_cDatabase, "columns", database_columns, 1);
	rb_define_method(rb_cDatabase, "cursor", database_cursor, -1);

	/* class Statement ---------------------------------------------------- */
	rb_cStatement = rb_define_class_under(rb_mInformix, "Statement", rb_cObject);
	rb_define_alloc_func(rb_cStatement, statement_alloc);
	rb_define_method(rb_cStatement, "initialize", statement_initialize, 2);
	rb_define_method(rb_cStatement, "[]", statement_call, -1);
	rb_define_alias(rb_cStatement, "call", "[]");
	rb_define_alias(rb_cStatement, "execute", "[]");
	rb_define_method(rb_cStatement, "drop", statement_drop, 0);

	/* module SequentialCursor -------------------------------------------- */
	rb_mSequentialCursor = rb_define_module_under(rb_mInformix, "SequentialCursor");
	rb_define_method(rb_mSequentialCursor, "fetch", seqcur_fetch, 0);
	rb_define_method(rb_mSequentialCursor, "fetch_hash", seqcur_fetch_hash, 0);
	rb_define_method(rb_mSequentialCursor, "fetch_many", seqcur_fetch_many, 1);
	rb_define_method(rb_mSequentialCursor, "fetch_all", seqcur_fetch_all, 0);

	/* InsertCursor ------------------------------------------------------- */
	rb_define_method(rb_mInsertCursor, "put", inscur_put, -1);
	rb_define_method(rb_mInsertCursor, "flush", inscur_flush, 0);

	/* class Cursor ------------------------------------------------------- */
	rb_cCursor = rb_define_class_under(rb_mInformix, "Cursor", rb_cObject);
	rb_define_alloc_func(rb_cCursor, cursor_alloc);
	rb_define_method(rb_cCursor, "initialize", cursor_initialize, 3);
	rb_define_method(rb_cCursor, "open", cursor_open, -1);
	rb_define_method(rb_cCursor, "close", cursor_close, 0);
	rb_define_method(rb_cCursor, "drop", cursor_drop, 0);

	/* Global constants --------------------------------------------------- */
	rb_require("date");
	rb_cDate = rb_const_get(rb_cObject, rb_intern("Date"));

	/* Global symbols ----------------------------------------------------- */
	s_read = rb_intern("read");
	s_new = rb_intern("new");
	s_utc = rb_intern("utc");
	s_day = rb_intern("day");
	s_month = rb_intern("month");
	s_year = rb_intern("year");
	s_hour = rb_intern("hour");
	s_min = rb_intern("min");
	s_sec = rb_intern("sec");
	s_usec = rb_intern("usec");
	sym_name = ID2SYM(rb_intern("name"));
	sym_type = ID2SYM(rb_intern("type"));
	sym_nullable = ID2SYM(rb_intern("nullable"));
	sym_stype = ID2SYM(rb_intern("stype"));
	sym_length = ID2SYM(rb_intern("length"));
	sym_precision = ID2SYM(rb_intern("precision"));
	sym_scale = ID2SYM(rb_intern("scale"));
	sym_default = ID2SYM(rb_intern("default"));
	sym_scroll = ID2SYM(rb_intern("scroll"));
	sym_hold = ID2SYM(rb_intern("hold"));
}
