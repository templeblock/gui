/**  <title>NSKeyValueBinding informal protocol reference</title>

   Implementation of KeyValueBinding for GNUStep

   Copyright (C) 2007 Free Software Foundation, Inc.

   Written by:  Chris Farber <chris@chrisfarber.net>
   Date: 2007

   This file is part of the GNUstep GUI Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 3 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; see the file COPYING.LIB.
   If not, see <http://www.gnu.org/licenses/> or write to the 
   Free Software Foundation, 51 Franklin Street, Fifth Floor, 
   Boston, MA 02110-1301, USA.
*/

#include <Foundation/NSArray.h>
#include <Foundation/NSDictionary.h>
#include <Foundation/NSEnumerator.h>
#include <Foundation/NSException.h>
#include <Foundation/NSInvocation.h>
#include <Foundation/NSKeyValueObserving.h>
#include <Foundation/NSKeyValueCoding.h>
#include <Foundation/NSLock.h>
#include <Foundation/NSMapTable.h>
#include <Foundation/NSValue.h>
#include <Foundation/NSValueTransformer.h>
#include <GNUstepBase/GSLock.h>

#include "AppKit/NSKeyValueBinding.h"
#include "GSBindingHelpers.h"

@implementation NSObject (NSKeyValueBindingCreation)

+ (void) exposeBinding: (NSString *)binding
{
  [GSKeyValueBinding exposeBinding:  binding forClass: [self class]];
}

- (NSArray *) exposedBindings
{
  NSMutableArray *exposedBindings = [NSMutableArray array];
  NSArray *tmp;
  Class class = [self class];

  while (class && class != [NSObject class])
    {
      tmp = [GSKeyValueBinding exposedBindingsForClass: class];
      if (tmp != nil)
        {
          [exposedBindings addObjectsFromArray: tmp];
        }
  
      class = [class superclass];
    }

  return exposedBindings;
}

- (Class) valueClassForBinding: (NSString *)binding
{
  return [NSString class];
}

- (void)bind: (NSString *)binding 
    toObject: (id)anObject
 withKeyPath: (NSString *)keyPath
     options: (NSDictionary *)options
{
  if ((anObject == nil)
      || (keyPath == nil))
    {
      NSLog(@"No object or path for binding on %@ for %@", self, binding);
      return;
    }

  if ([[self exposedBindings] containsObject: binding])
    {
      [self unbind: binding];
      [[GSKeyValueBinding alloc] initWithBinding: binding 
                                 withName: binding 
                                 toObject: anObject
                                 withKeyPath: keyPath
                                 options: options
                                 fromObject: self];
    }
  else
    {
      NSLog(@"No binding exposed on %@ for %@", self, binding);
    }
}

- (NSDictionary *) infoForBinding: (NSString *)binding
{
  return [GSKeyValueBinding infoForBinding: binding forObject: self];
}

- (void) unbind: (NSString *)binding
{
  [GSKeyValueBinding unbind: binding forObject: self];
}

@end

static NSRecursiveLock *bindingLock = nil;
static NSMapTable *classTable = NULL;      //available bindings
static NSMapTable *objectTable = NULL;     //bound bindings

typedef enum {
  GSBindingOperationAnd = 0,
  GSBindingOperationOr
} GSBindingOperationKind;

//TODO: document
BOOL GSBindingResolveMultipleValueBool(NSString *key, NSDictionary *bindings,
    GSBindingOperationKind operationKind);

//TODO: document
void GSBindingInvokeAction(NSString *targetKey, NSString *argumentKey,
    NSDictionary *bindings);

NSArray *GSBindingExposeMultipleValueBindings(
    NSArray *bindingNames,
    NSMutableDictionary *bindingList);

NSArray *GSBindingExposePatternBindings(
    NSArray *bindingNames,
    NSMutableDictionary *bindingList);

id GSBindingReverseTransformedValue(id value, NSDictionary *options);

@implementation GSKeyValueBinding

+ (void) initialize
{
  if (self == [GSKeyValueBinding class])
    {
      bindingLock = [GSLazyRecursiveLock new];
      classTable = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
          NSOwnedPointerMapValueCallBacks, 128);
      objectTable = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
          NSOwnedPointerMapValueCallBacks, 128);
    }
}

+ (void) exposeBinding: (NSString *)binding forClass: (Class)clazz
{
  NSMutableArray *bindings;

  [bindingLock lock];
  bindings = (NSMutableArray *)NSMapGet(classTable, (void*)clazz);
  if (bindings == nil)
    {
      // Need to retain it ourselves
      bindings = [[NSMutableArray alloc] initWithCapacity: 5];
      NSMapInsert(classTable, (void*)clazz, (void*)bindings);
    }
  [bindings addObject: binding];
  [bindingLock unlock];
}

+ (NSArray *) exposedBindingsForClass: (Class)clazz
{
  NSArray *tmp;

  if (!classTable)
    return nil;

  [bindingLock lock];
  tmp = NSMapGet(classTable, (void*)clazz);
  [bindingLock unlock];
  
  return tmp;
}

+ (NSDictionary *) infoForBinding: (NSString *)binding forObject: (id)anObject
{
  NSMutableDictionary *bindings;
  GSKeyValueBinding *theBinding;

  if (!objectTable)
    return nil;

  [bindingLock lock];
  bindings = (NSMutableDictionary *)NSMapGet(objectTable, (void *)anObject);
  if (bindings != nil)
    {
      theBinding = (GSKeyValueBinding*)[bindings objectForKey: binding];
    }
  [bindingLock unlock];

  return theBinding->info;
}

+ (void) unbind: (NSString *)binding  forObject: (id)anObject
{
  NSMutableDictionary *bindings;
  id observedObject;
  NSString *keyPath;
  GSKeyValueBinding *theBinding;

  if (!objectTable)
    return;

  [bindingLock lock];
  bindings = (NSMutableDictionary *)NSMapGet(objectTable, (void *)anObject);
  if (bindings != nil)
    {
      theBinding = (GSKeyValueBinding*)[bindings objectForKey: binding];
      if (theBinding != nil)
        {
          observedObject = [theBinding->info objectForKey: NSObservedObjectKey];
          keyPath = [theBinding->info objectForKey: NSObservedKeyPathKey];
          [observedObject removeObserver: theBinding forKeyPath: keyPath];
          [bindings setValue: nil forKey: binding];
        }
    }
  [bindingLock unlock];
}

+ (void) unbindAllForObject: (id)anObject
{
  NSEnumerator *enumerator;
  NSString *binding;
  NSDictionary *list;

  if (!objectTable)
    return;

  [bindingLock lock];
  list = (NSDictionary *)NSMapGet(objectTable, (void *)anObject);
  if (list != nil)
    {
      enumerator = [list keyEnumerator];
      while ((binding = [enumerator nextObject]))
        {
          [anObject unbind: binding];
        }
      NSMapRemove(objectTable, (void *)anObject);
      RELEASE(list);
    }
  [bindingLock unlock];
}

- (id) initWithBinding: (NSString *)binding 
              withName: (NSString *)name
              toObject: (id)dest
           withKeyPath: (NSString *)keyPath
               options: (NSDictionary *)options
            fromObject: (id)source
{
  NSMutableDictionary *bindings;
  
  src = source;
  if (options == nil)
    {
      info = [[NSDictionary alloc] initWithObjectsAndKeys:
        dest, NSObservedObjectKey,
        keyPath, NSObservedKeyPathKey,
        nil];
    }
  else
    {
      info = [[NSDictionary alloc] initWithObjectsAndKeys:
        dest, NSObservedObjectKey,
        keyPath, NSObservedKeyPathKey,
        options, NSOptionsKey,
        nil];
    }
    
  [dest addObserver: self
        forKeyPath: keyPath
        options: NSKeyValueObservingOptionNew
        context: binding];

  [bindingLock lock];
  bindings = (NSMutableDictionary *)NSMapGet(objectTable, (void *)source);
  if (bindings == nil)
    {
      bindings = [NSMutableDictionary new];
      NSMapInsert(objectTable, (void*)source, (void*)bindings);
    }
  [bindings setObject: self forKey: name];
  [bindingLock unlock];

  [self setValueFor: binding];

  return self;
}

- (void)dealloc
{
  DESTROY(info);
  src = nil; 
  [super dealloc];
}

- (void) setValueFor: (NSString *)binding 
{
  id newValue;
  id dest;
  NSString *keyPath;
  NSDictionary *options;

  dest = [info objectForKey: NSObservedObjectKey];
  keyPath = [info objectForKey: NSObservedKeyPathKey];
  options = [info objectForKey: NSOptionsKey];

  newValue = [dest valueForKeyPath: keyPath];
  newValue = [self transformValue: newValue withOptions: options];
  [src setValue: newValue forKey: binding];
}

- (void) observeValueForKeyPath: (NSString *)keyPath
                       ofObject: (id)object
                         change: (NSDictionary *)change
                        context: (void *)context
{
  NSString *binding = (NSString *)context;
  NSDictionary *options;
  id newValue;

  options = [info objectForKey: NSOptionsKey];
  newValue = [change objectForKey: NSKeyValueChangeNewKey];
  newValue = [self transformValue: newValue withOptions: options];
  [src setValue: newValue forKey: binding];
}

- (id) transformValue: (id)value withOptions: (NSDictionary *)options
{
  NSString *valueTransformerName;
  NSValueTransformer *valueTransformer;
  NSString *placeholder;

  if (value == NSMultipleValuesMarker)
    {
      placeholder = [options objectForKey: NSMultipleValuesPlaceholderBindingOption];
      if (placeholder == nil)
        {
          placeholder = @"Multiple Values";
        }
      return placeholder;
    }
  if (value == NSNoSelectionMarker)
    {
      placeholder = [options objectForKey: NSNoSelectionPlaceholderBindingOption];
      if (placeholder == nil)
        {
          placeholder = @"No Selection";
        }
      return placeholder;
    }
  if (value == NSNotApplicableMarker)
    {
      if ([[options objectForKey: NSRaisesForNotApplicableKeysBindingOption]
          boolValue])
        {
          [NSException raise: NSGenericException
                      format: @"This binding does not accept not applicable keys"];
        }

      placeholder = [options objectForKey:
        NSNotApplicablePlaceholderBindingOption];
      if (placeholder == nil)
        {
          placeholder = @"Not Applicable";
        }
      return placeholder;
    }
  if (value == nil)
    {
      placeholder = [options objectForKey:
        NSNullPlaceholderBindingOption];
      if (placeholder == nil)
        {
          placeholder = @"";
        }
      return placeholder;
    }

  valueTransformerName = [options objectForKey:
    NSValueTransformerNameBindingOption];
  if (valueTransformerName != nil)
    {
      valueTransformer = [NSValueTransformer valueTransformerForName:
                                                 valueTransformerName];
    }
  else
    {
      valueTransformer = [options objectForKey:
                                      NSValueTransformerBindingOption];
    }

  if (valueTransformer != nil)
    {
      value = [valueTransformer transformedValue: value];
    }

  return value;
}

@end

@implementation GSKeyValueOrBinding : GSKeyValueBinding 

- (void) setValueFor: (NSString *)binding 
{
  NSDictionary *bindings;
  BOOL res;
  
  if (!objectTable)
    return;

 [bindingLock lock];
  bindings = (NSDictionary *)NSMapGet(objectTable, (void *)src);
  if (!bindings)
    return;

  res = GSBindingResolveMultipleValueBool(binding, bindings,
                                          GSBindingOperationOr);
  [bindingLock unlock];
  [src setValue: [NSNumber numberWithBool: res] forKey: binding];
}

- (void) observeValueForKeyPath: (NSString *)keyPath
                       ofObject: (id)object
                         change: (NSDictionary *)change
                        context: (void *)context
{
  [self setValueFor: (NSString*)context];
}

@end

@implementation GSKeyValueAndBinding : GSKeyValueBinding 

- (void) setValueFor: (NSString *)binding 
{
  NSDictionary *bindings;
  BOOL res;
  
  if (!objectTable)
    return;

 [bindingLock lock];
  bindings = (NSDictionary *)NSMapGet(objectTable, (void *)src);
  if (!bindings)
    return;

  res = GSBindingResolveMultipleValueBool(binding, bindings,
                                          GSBindingOperationAnd);
  [bindingLock unlock];
  [src setValue: [NSNumber numberWithBool: res] forKey: binding];
}

- (void) observeValueForKeyPath: (NSString *)keyPath
                       ofObject: (id)object
                         change: (NSDictionary *)change
                        context: (void *)context
{
  [self setValueFor: (NSString*)context];
}

@end


//Helper functions
BOOL GSBindingResolveMultipleValueBool(NSString *key, NSDictionary *bindings,
    GSBindingOperationKind operationKind)
{
  NSString *bindingName;
  NSDictionary *info;
  int count = 1;
  id object;
  NSString *keyPath;
  id value;
  NSDictionary *options;
  GSKeyValueBinding *theBinding;

  bindingName = key;
  while ((theBinding = [bindings objectForKey: bindingName]))
    {
      info = theBinding->info;
      object = [info objectForKey: NSObservedObjectKey];
      keyPath = [info objectForKey: NSObservedKeyPathKey];
      options = [info objectForKey: NSOptionsKey];

      value = [object valueForKeyPath: keyPath];
      value = [theBinding transformValue: value withOptions: options];
      if ([value boolValue] == operationKind)
        {
          return operationKind;
        }
      bindingName = [NSString stringWithFormat: @"%@%i", key, ++count];
    }
  return !operationKind;
}

void GSBindingInvokeAction(NSString *targetKey, NSString *argumentKey,
    NSDictionary *bindings)
{
  NSString *bindingName;
  NSDictionary *info;
  NSDictionary *options;
  int count = 1;
  id object;
  id target;
  SEL selector;
  NSString *keyPath;
  NSInvocation *invocation;
  GSKeyValueBinding *theBinding;

  theBinding = [bindings objectForKey: targetKey];
  info = theBinding->info;
  object = [info objectForKey: NSObservedObjectKey];
  keyPath = [info objectForKey: NSObservedKeyPathKey];
  options = [info objectForKey: NSOptionsKey];

  target = [object valueForKeyPath: keyPath];
  selector = NSSelectorFromString([options objectForKey: 
      NSSelectorNameBindingOption]);
  if (target == nil || selector == NULL) return;

  invocation = [NSInvocation invocationWithMethodSignature:
    [target methodSignatureForSelector: selector]];
  [invocation setSelector: selector];

  bindingName = argumentKey;
  while ((theBinding = [bindings objectForKey: bindingName]))
    {
      info = theBinding->info;
      object = [info objectForKey: NSObservedObjectKey];
      keyPath = [info objectForKey: NSObservedKeyPathKey];
      if ((object = [object valueForKeyPath: keyPath]))
        {
          [invocation setArgument: object atIndex: ++count];
        }
      bindingName = [NSString stringWithFormat: @"%@%i", argumentKey, count];
    }
  [invocation invoke];
}

void GSBindingLock()
{
  [bindingLock lock];
}

void GSBindingReleaseLock()
{
  [bindingLock unlock];
}

NSMutableDictionary *GSBindingListForObject(id object)
{
  NSMutableDictionary *list;

  if (!objectTable)
    return nil;

  list = (NSMutableDictionary *)NSMapGet(objectTable, (void *)object);
  if (list == nil)
    {
      list = [NSMutableDictionary new];
      NSMapInsert(objectTable, (void *)object, (void *)list);
    }
  return list;
}

NSArray *GSBindingExposeMultipleValueBindings(
    NSArray *bindingNames,
    NSMutableDictionary *bindingList)
{
  NSEnumerator *nameEnum;
  NSString *name;
  NSString *numberedName;
  NSMutableArray *additionalBindings;
  int count;

  additionalBindings = [NSMutableArray array];
  nameEnum = [bindingNames objectEnumerator];
  while ((name = [nameEnum nextObject]))
    {
      count = 1;
      numberedName = name;
      while ([bindingList objectForKey: numberedName] != nil)
        {
          numberedName = [NSString stringWithFormat: @"%@%i", name, ++count];
          [additionalBindings addObject: numberedName];
        }
    }
  return additionalBindings;
}


NSArray *GSBindingExposePatternBindings(
    NSArray *bindingNames,
    NSMutableDictionary *bindingList)
{
  NSEnumerator *nameEnum;
  NSString *name;
  NSString *numberedName;
  NSMutableArray *additionalBindings;
  int count;

  additionalBindings = [NSMutableArray array];
  nameEnum = [bindingNames objectEnumerator];
  while ((name = [nameEnum nextObject]))
    {
      count = 1;
      numberedName = [NSString stringWithFormat:@"%@1", name];
      while ([bindingList objectForKey: numberedName] != nil)
        {
          numberedName = [NSString stringWithFormat:@"%@%i", name, ++count];
          [additionalBindings addObject: numberedName];
        }
    }
  return additionalBindings;
}

id GSBindingReverseTransformedValue(id value, NSDictionary *options)
{
  NSValueTransformer *valueTransformer;
  NSString *valueTransformerName;

  valueTransformerName = [options objectForKey: 
    NSValueTransformerNameBindingOption];
  valueTransformer = [NSValueTransformer valueTransformerForName:
    valueTransformerName];
  if (valueTransformer && [[valueTransformer class]
      allowsReverseTransformation])
    {
      value = [valueTransformer reverseTransformedValue: value];
    }
  return value;
}

/*
@interface _GSStateMarker : NSObject
{
  NSString * description;
}
@end

@implementation _GSStateMarker

- (id) initWithType: (int)type
{
  if (type == 0)
    {
      description = @"<MULTIPLE VALUES MARKER>";
    }
  else if (type == 1)
    {
     description = @"<NO SELECTION MARKER>";
    }
  else
    {
      description = @"<NOT APPLICABLE MARKER>";
    }

  return self;
}

- (id) valueForKey: (NSString *)key
{
  return self;
}

- (id) retain { return self; }
- (oneway void) release {}

- (NSString *) description
{
  return description;
}

@end
*/