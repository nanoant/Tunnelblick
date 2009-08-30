/*
 *  Copyright (c) 2005, 2006, 2007, 2008, 2009 Angelo Laub
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License version 2
 *  as published by the Free Software Foundation.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program (see the file COPYING included with this
 *  distribution); if not, write to the Free Software Foundation, Inc.,
 *  59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#import <Cocoa/Cocoa.h>
#import "KeyChain.h"
#import "NetSocket.h"
#import <Foundation/NSDebug.h>

@interface AuthAgent : NSObject {
	NSString * authMode;
	NSString * configName;
	KeyChain * keyChainManager;
	NSString * passphrase;
	NSString * password;
	NSString * username;
}

-(NSString *)   authMode;
-(void)         setAuthMode:                        (NSString *)value;

-(NSString *)   configName;
-(void)         setConfigName:                      (NSString *)value;

-(NSString *)   passphrase;
-(void)         setPassphrase:                      (NSString *)value;

-(NSString *)   password;
-(void)         setPassword:                        (NSString *)value;

-(NSString *)   username;
-(void)         setUsername:                        (NSString *)value;

-(void)         deletePassphraseFromKeychain;
-(NSArray *)    getAuth;
-(id)           initWithConfigName:                 (NSString *)inConfigName;
-(void)         loadKeyChainManager;
-(void)         performAuthentication;
-(void)         performPasswordAuthentication;
-(void)         performPrivateKeyAuthentication;
-(BOOL)         keychainHasPassphrase;

@end
