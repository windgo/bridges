/*******************************************************************************
 *
 * Copyright 2012 Zack Grossbart
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
 *
 ******************************************************************************/

#import "LevelLayer.h"
#import "BridgeNode.h"
#import "Bridge4Node.h"
#import "HouseNode.h"
#import "BridgeColors.h"
#import "RiverNode.h"
#import "Level.h"
#import "Undoable.h"

//#define PTM_RATIO 32.0

@interface LevelLayer() {
    bool _reportedWon;
    CGPoint _playerStart;
}
    @property (readwrite, retain) NSMutableArray *undoStack;
    @property (nonatomic, retain) PlayerNode *player;
@end

@implementation LevelLayer


+ (id)scene {
    
    CCScene *scene = [CCScene node];
    LevelLayer *layer = [LevelLayer node];
    layer.tag = LEVEL;
    [scene addChild:layer];
    return scene;
    
}


- (id)init {
    
    if( (self=[super initWithColor:ccc4(255,255,255,255)] )) {
        
        director_ = (CCDirectorIOS*) [CCDirector sharedDirector];
        
        _inCross = false;
        
        b2Vec2 gravity = b2Vec2(0.0f, 0.0f);
        bool doSleep = false;
        _world = new b2World(gravity);
        _world->SetAllowSleeping(doSleep);
        
        [self schedule:@selector(tick:)];
        
        // Enable debug draw
        _debugDraw = new GLESDebugDraw( PTM_RATIO );
        _world->SetDebugDraw(_debugDraw);
        
        uint32 flags = 0;
        flags += b2Draw::e_shapeBit;
        _debugDraw->SetFlags(flags);
        
        // Create contact listener
        _contactListener = new MyContactListener();
        _world->SetContactListener(_contactListener);
        
        // Create our sprite sheet and frame cache
        _spriteSheet = [[CCSpriteBatchNode batchNodeWithFile:@"octosprite.png"
                                                    capacity:2] retain];
        [[CCSpriteFrameCache sharedSpriteFrameCache]
         addSpriteFramesWithFile:@"octosprite.plist"];
        [self addChild:_spriteSheet];
        
        self.undoStack = [[NSMutableArray alloc] init];
        _canVisit = true;
        
        _layerMgr = [[LayerMgr alloc] initWithSpriteSheet:_spriteSheet:_world];
        
        //        [self spawnPlayer];
        
        self.isTouchEnabled = YES;
    }
    return self;
    
}

-(void)readLevel {    
 //   [level.rivers makeObjectsPerformSelector:@selector(addSprite:)];
    
    [self.currentLevel addSprites:_layerMgr:self.view];
    
    if (self.currentLevel.playerPos.x > -1) {
        [self spawnPlayer:self.currentLevel.playerPos.x :self.currentLevel.playerPos.y];
    }
    
    if ([self.currentLevel hasCoins]) {
        self.coinLbl.text = [NSString stringWithFormat:@"%i", 0];
        self.coinImage.hidden = NO;
    } else {
        self.coinLbl.text = @"";
        self.coinImage.hidden = YES;
    }
    
    
    //[level dealloc];
}

-(void)reset {
    [self.currentLevel removeSprites: _layerMgr: self.view];
    [_layerMgr removeAll];
    
    
    [self.undoStack removeAllObjects];
    UIImage *undoD = [UIImage imageNamed:@"left_arrow_d.png"];
    [_undoBtn setImage:undoD forState:UIControlStateNormal];
    
    [_player dealloc];
    _player = nil;
    
    _reportedWon = false;
}

-(void)setLevel:(Level*) level {
    if (self.currentLevel && [level.levelId isEqualToString:self.currentLevel.levelId]) {
        /*
         * If we already have that layer we just ignore it
         */
        return;
    }
    
    [self reset];
    
    self.currentLevel = level;
    
    /*
     * The first time we run we don't have the window dimensions
     * so we can't draw yet and we wait to add the level until the 
     * first draw.  After that we have the dimensions so we can 
     * just set the new level.
     */
    if (_hasInit) {
        [self readLevel];
    }
}

-(void)undo {
    if (self.undoStack.count == 0) {
        // There's nothing to undo
        return;
    }
    
    Undoable *undo = [self.undoStack objectAtIndex:self.undoStack.count - 1];
    
    [undo.node undo];
    [self.player updateColor:undo.color];
    self.player.player.position = undo.pos;
    self.player.coins = undo.coins;
    self.coinLbl.text = [NSString stringWithFormat:@"%i", _player.coins];
    
    [self.undoStack removeLastObject];
    
    if (self.undoStack.count == 0) {
        UIImage *undoD = [UIImage imageNamed:@"left_arrow_d.png"];
        [_undoBtn setImage:undoD forState:UIControlStateNormal];
    } else {
        UIImage *undoD = [UIImage imageNamed:@"left_arrow.png"];
        [_undoBtn setImage:undoD forState:UIControlStateNormal];
    }
    
}

-(void)refresh {
    [self reset];
    Level *level = self.currentLevel;
    self.currentLevel = nil;
    
    [self setLevel:level];
    
    
}

-(void)draw {
    
    [super draw];
    
    CGSize s = [[CCDirector sharedDirector] winSize];
    
    ccDrawSolidRect( ccp(0, 0), ccp(s.width, s.height), ccc4f(255, 255, 255, 255) );
    
    if (!_hasInit) {
        /*
         * The director doesn't know the window width correctly
         * until we do the first draw so we need to delay adding
         * our objects which rely on knowing the dimensions of
         * the window until that happens.
         */
        _layerMgr.tileSize = CGSizeMake(s.height / TILE_COUNT, s.height / TILE_COUNT);
        [self readLevel];
    
       // [self addRivers];
        
        _hasInit = true;
    }
    
//     _world->DrawDebugData();
}


- (void)tick:(ccTime)dt {
    if (_inCross) {
        /*
         * We get a lot of collisions when crossing a bridge
         * and we just want to ignore them until we're done.
         */
        return;
    }
    
    _world->Step(dt, 10, 10);
    for(b2Body *b = _world->GetBodyList(); b; b=b->GetNext()) {
        if (b->GetUserData() != NULL) {
            CCSprite *sprite = (CCSprite *)b->GetUserData();
            
            b2Vec2 b2Position = b2Vec2(sprite.position.x/PTM_RATIO,
                                       sprite.position.y/PTM_RATIO);
            float32 b2Angle = -1 * CC_DEGREES_TO_RADIANS(sprite.rotation);
            
            b->SetTransform(b2Position, b2Angle);
        }
    }
    
    //    std::vector<b2Body *>toDestroy;
    std::vector<MyContact>::iterator pos;
    for(pos = _contactListener->_contacts.begin();
        pos != _contactListener->_contacts.end(); ++pos) {
        MyContact contact = *pos;
        
        b2Body *bodyA = contact.fixtureA->GetBody();
        b2Body *bodyB = contact.fixtureB->GetBody();
        if (bodyA->GetUserData() != NULL && bodyB->GetUserData() != NULL) {            
            CCSprite *spriteA = (CCSprite *) bodyA->GetUserData();
            CCSprite *spriteB = (CCSprite *) bodyB->GetUserData();
            
            if (spriteA.tag == RIVER && spriteB.tag == PLAYER) {
                [self bumpObject:spriteB:spriteA];
            } else if (spriteA.tag == PLAYER && spriteB.tag == RIVER) {
                [self bumpObject:spriteA:spriteB];
            } else if (spriteA.tag == BRIDGE && spriteB.tag == PLAYER) {
                [self crossBridge:spriteB:spriteA];
            } else if (spriteA.tag == PLAYER && spriteB.tag == BRIDGE) {
                [self crossBridge:spriteA:spriteB];
            } else if (spriteA.tag == BRIDGE4 && spriteB.tag == PLAYER) {
                [self crossBridge4:spriteB:spriteA];
            } else if (spriteA.tag == PLAYER && spriteB.tag == BRIDGE4) {
                [self crossBridge4:spriteA:spriteB];
            } else if (spriteA.tag == HOUSE && spriteB.tag == PLAYER) {
                [self visitHouse:spriteB:spriteA];
            } else if (spriteA.tag == PLAYER && spriteB.tag == HOUSE) {
                [self visitHouse:spriteA:spriteB];
            }
        }
    }
}

-(BridgeNode*)findBridge:(CCSprite*) bridge {
    for (BridgeNode *n in self.currentLevel.bridges) {
        if (n.bridge == bridge) {
            return n;
        }
    }
    
    return nil;
}

-(Bridge4Node*)findBridge4:(CCSprite*) bridge {
    for (Bridge4Node *n in self.currentLevel.bridge4s) {
        if (n.bridge == bridge) {
            return n;
        }
    }
    
    return nil;
}

-(HouseNode*)findHouse:(CCSprite*) house {
    for (HouseNode *n in self.currentLevel.houses) {
        if (n.house == house) {
            return n;
        }
    }
    
    return nil;
}

- (void)visitHouse:(CCSprite *) player:(CCSprite*) house {
    /*
     * The player has run into a house.  We need to visit the house
     * if the player is the right color and bump it if it isn't
     */
    HouseNode *node = [self findHouse:house];
    
    if (_canVisit && ![node isVisited]) {
        if (node.color == NONE || _player.color == node.color) {
            [self.undoStack addObject: [[Undoable alloc] initWithPosAndNode:_prevPlayerPos :node: _player.color: _player.coins]];
            UIImage *undoD = [UIImage imageNamed:@"left_arrow.png"];
            [_undoBtn setImage:undoD forState:UIControlStateNormal];
            if (node.coins > 0) {
                _player.coins++;
                self.coinLbl.text = [NSString stringWithFormat:@"%i", _player.coins];
            }
            [node visit];
            _canVisit = false;
        }
    }
    
    [self bumpObject:player:house];
    
}

- (void)crossBridge:(CCSprite *) player:(CCSprite*) bridge {
    /*
     * The player has run into a bridge.  We need to cross the bridge
     * if it hasn't been crossed yet and not if it has.
     */
    BridgeNode *node = [self findBridge:bridge];
    
    if ([node isCrossed] || (node.coins > 0 && _player.coins < 1)) {
        [self bumpObject:player:bridge];
    } else {
        _inCross = true;
        [self doCross:player:node:bridge];
    }
    
}

- (void)crossBridge4:(CCSprite *) player:(CCSprite*) bridge {
    
    if (_inBridge) {
        return;
    }
    /*
     * The player has run into a 4-way bridge.  We need to cross the bridge
     * if it hasn't been crossed yet and not if it has.
     */
    Bridge4Node *node = [self findBridge4:bridge];
    
    if ([node isCrossed]) {
        [self bumpObject:player:bridge];
    } else {
        _inCross = true;
        _inBridge = true;
        [self doCross4:player:node:bridge];
    }
    
}

- (void)finishCross4: (CGPoint) touch {
    int exitDir = -1;
    
    CGPoint p0 = _player.player.position;
    CGPoint p1 = touch;
    CGPoint pnormal = ccpSub(p1, p0);
    CGFloat angle = CGPointToDegree(pnormal);
    
    if (angle > 45 && angle < 135) {
        exitDir = RIGHT;
    } else if ((angle > 135 && angle < 180) || (angle < -135 && angle > -180)) {
        exitDir = DOWN;
    } else if (angle < -45 && angle > -135) {
        exitDir = LEFT;
    } else {
        exitDir = UP;
    }
    
    if (exitDir == _bridgeEntry) {
        /*
         * You can't exit the bridge from the same direction you enter it
         */
        return;
    }
        
    CGPoint location;
    
//    printf("current bridge (%f, %f)\n", _currentBridge.bridge.position.x, _currentBridge.bridge.position.y);
    
    if (exitDir == RIGHT) {
        location = ccp(_currentBridge.bridge.position.x + (_currentBridge.bridge.contentSize.width / 2) + (_player.player.contentSize.width), _currentBridge.bridge.position.y);
    } else if (exitDir == LEFT) {
        location = ccp((_currentBridge.bridge.position.x - (_currentBridge.bridge.contentSize.width / 2)) - (_player.player.contentSize.width), _currentBridge.bridge.position.y);
    } else if (exitDir == UP) {
        location = ccp(_currentBridge.bridge.position.x, _currentBridge.bridge.position.y + (_currentBridge.bridge.contentSize.height / 2) + (_player.player.contentSize.height));
    } else if (exitDir == DOWN) {
        location = ccp(_currentBridge.bridge.position.x, (_currentBridge.bridge.position.y - (_currentBridge.bridge.contentSize.height / 2)) - (_player.player.contentSize.height));
    }
    
    [_player moveTo: location:true];
    
    [_currentBridge cross];
    _canVisit = true;
    _currentBridge = nil;
    _inBridge = false;
    
    [self hasWon];
}

CGFloat CGPointToDegree(CGPoint point) {
    CGFloat bearingRadians = atan2f(point.x, point.y);
    CGFloat bearingDegrees = bearingRadians * (180. / M_PI);
    return bearingDegrees;
}

- (void)doCross4:(CCSprite *) player:(Bridge4Node*) bridge:(CCSprite*) object {
    CCActionManager *mgr = [player actionManager];
    [mgr pauseTarget:player];
    _inMove = true;
    
    /*
     * When the player hits a 4-way bridge we take them to the middle of the bridge
     * and make them tap again to decide which way they'll exit the bridge.
     */
    CGPoint location = ccp(bridge.bridge.position.x, bridge.bridge.position.y);
    
    int padding = bridge.bridge.contentSize.width / 2;
    
    if (player.position.x < bridge.bridge.position.x - padding) {
        _bridgeEntry = LEFT;
    } else if (player.position.x > bridge.bridge.position.x + padding) {
        _bridgeEntry = RIGHT;
    } else if (player.position.y < bridge.bridge.position.y - padding) {
        _bridgeEntry = DOWN;
    } else if (player.position.y > bridge.bridge.position.y - padding) {
        _bridgeEntry = UP;
    }
    
    _currentBridge = bridge;
    
    
    [mgr removeAllActionsFromTarget:player];
    [mgr resumeTarget:player];
    
    //    printf("Moving to (%f, %f)\n", location.x, location.y);
    //    location.y += 5;
    //    _player.position = location;
    
    [self.undoStack addObject: [[Undoable alloc] initWithPosAndNode:_prevPlayerPos :bridge: _player.color: _player.coins]];
    UIImage *undoD = [UIImage imageNamed:@"left_arrow.png"];
    [_undoBtn setImage:undoD forState:UIControlStateNormal];
    
    [_player moveTo: ccp(location.x, location.y):true];
    
    [bridge enterBridge:_bridgeEntry];
    
    if (bridge.color != NONE) {
        [_player updateColor:bridge.color];
    }
}

- (void)doCross:(CCSprite *) player:(BridgeNode*) bridge:(CCSprite*) object {
    CCActionManager *mgr = [player actionManager];
    [mgr pauseTarget:player];
    _inMove = true;
    
    CGPoint location;
    
    int padding = bridge.bridge.contentSize.width / 2;
    
//    printf("player (%f, %f)\n", player.position.x, player.position.y);
//    printf("bridge (%f, %f)\n", object.position.x, object.position.y);
//    printf("vertical: %i\n", bridge.vertical);
    
    if (bridge.vertical) {
        if (_playerStart.y + player.contentSize.height < object.position.y + padding) {
            // Then the player is below the bridge
            if (bridge.direction != UP && bridge.direction != NONE) {
                [self bumpObject:player :bridge.bridge];
                return;
            }
            int x = (object.position.x + (object.contentSize.width / 2)) -
                (player.contentSize.width);
            location = ccp(x, object.position.y + object.contentSize.height + 1);
        } else if (_playerStart.y > (object.position.y + object.contentSize.height) - padding) {
            // Then the player is above the bridge
            if (bridge.direction != DOWN && bridge.direction != NONE) {
                [self bumpObject:player :bridge.bridge];
                return;
            }
            int x = (object.position.x + (object.contentSize.width / 2)) -
                (player.contentSize.width);
            location = ccp(x, (object.position.y - 1) - (player.contentSize.height * 2));
        }
    } else {
        if (_playerStart.x > (object.position.x + object.contentSize.width) - padding) {
            // Then the player is to the right of the bridge
            if (bridge.direction != LEFT && bridge.direction != NONE) {
                [self bumpObject:player: bridge.bridge];
                return;
            }
            int y = (object.position.y + (object.contentSize.height / 2)) -
                (player.contentSize.height);
            location = ccp((object.position.x - 1) - (player.contentSize.width * 2), y);
        } else if (_playerStart.x + player.contentSize.width < object.position.x + padding) {
            // Then the player is to the left of the bridge
            if (bridge.direction != RIGHT && bridge.direction != NONE) {
                [self bumpObject:player :bridge.bridge];
                return;
            }
            int y = (object.position.y + (object.contentSize.height / 2)) -
                (player.contentSize.height);
            location = ccp(object.position.x + 1 + object.contentSize.width, y);
        }
    }
    
    /*if (location == NULL) {
        printf("player (%f, %f)\n", player.position.x, player.position.y);
        printf("river (%f, %f)\n", object.position.x, object.position.y);
        printf("This should never happen\n");
    }*/
    
    [mgr removeAllActionsFromTarget:player];
    [mgr resumeTarget:player];
    
    //    printf("Moving to (%f, %f)\n", location.x, location.y);
    //    location.y += 5;
    //    _player.position = location;
    
    [self.undoStack addObject: [[Undoable alloc] initWithPosAndNode:_prevPlayerPos :bridge: _player.color: _player.coins]];
    UIImage *undoD = [UIImage imageNamed:@"left_arrow.png"];
    [_undoBtn setImage:undoD forState:UIControlStateNormal];
    
    [_player moveTo: ccp(location.x, location.y):true];
    
    if (bridge.coins > 0) {
        _player.coins--;
        self.coinLbl.text = [NSString stringWithFormat:@"%i", _player.coins];
    }
    [bridge cross];
    _canVisit = true;
    
    if (bridge.color != NONE) {
        [_player updateColor:bridge.color];
    }
    
    [self hasWon];
}

/**
 * The player bumped into a river or crossed bridge and is now
 * in the middle of an animation overlapping a river.  We need
 * to stop the animation and move the player back off the river
 * so they aren't overlapping anymore.
 *
 * This method happens as the result of a colision.  I was hoping
 * that we'd be notified as soon as the colission happened, but 
 * instead the notification happens a variable time after the 
 * colision and while the objects are intersecting.  That means 
 * we can't use the position of the objects to determine their 
 * direction and we have to use the original starting position instead.
 */
- (void)bumpObject:(CCSprite *) player:(CCSprite*) object {
    
    
    if (_inMove) {
        return;
    }
    
    _inMove = true;
    
    CCActionManager *mgr = [player actionManager];
    [mgr pauseTarget:player];
    
    _player.player.position = [self pointOnLine: _playerStart: _player.player.position: 20];
    
    [_player playerMoveEnded];
    
    [mgr removeAllActionsFromTarget:player];
    [mgr resumeTarget:player];
    
    [self hasWon];
    
}

-(int) collidedSide:(CCSprite *) player:(CCSprite*) object {
    return [self collidedSideForRect:[player boundingBox] :[object boundingBox]];
}

-(int) collidedSideForRect:(CGRect) playerRect:(CGRect) objectRect {
    
    if (playerRect.origin.x < objectRect.origin.x) {
        /*
         * Then the right side of the player is to the right of the left
         * side of the object.  That means the player is on the left
         */
        return LEFT;
    } else if (playerRect.origin.x > objectRect.origin.x) {
        return RIGHT;
    } else if (playerRect.origin.y > objectRect.origin.y) {
        // The player is above the object
        return UP;
    } else if (playerRect.origin.y < objectRect.origin.y) {
        return DOWN;
    } else {
       /* printf("player (%f, %f)\n", player.position.x, player.position.y);
        printf("river (%f, %f)\n", object.position.x, object.position.y);
        printf("padding (%i)\n", padding);*/
        return -1;
    }
}

-(CGPoint)pointOnLine: (CGPoint) p1: (CGPoint) p2: (int) distance {
    
    /*float x1 = p1.x;
    float x2 = p2.x;
    float y1 = p1.y;
    float y2 = p2.y;
    
  //  float theta = atanf((y2 - y1) - (x2 - x1));
    
    float h = sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
    float xd = x2 - (distance / h) * (y2 - y1);
    float yd = y2 - (distance / h) * (x2 - x1);
    
    return ccp(xd, yd);*/
    
    double rads = atan2(p2.y - p1.y, p2.x - p1.x);
    
    double x3 = p2.x - distance * cos(rads);
    double y3 = p2.y - distance * sin(rads);
    
    return ccp(x3, y3);
    
    
    
}

-(void) hasWon {
    if (!_reportedWon && [self.currentLevel hasWon]) {
        _reportedWon = true;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        
        [defaults setBool:TRUE forKey:[NSString stringWithFormat:@"%@-won", self.currentLevel.levelId]];
        [defaults synchronize];
        
        [self.controller won];
    }
    
}

- (void)spawnPlayer:(int) x: (int) y {
    
    _player = [[PlayerNode alloc] initWithColor:BLACK:_layerMgr];
    _player.player.position = ccp(x, y);
    
    //   CCSprite *player = [_player player];
    /*
     [_player runAction:
     [CCSequence actions:
     [CCMoveTo actionWithDuration:1.0 position:ccp(300,100)],
     [CCMoveTo actionWithDuration:1.0 position:ccp(200,200)],
     [CCMoveTo actionWithDuration:1.0 position:ccp(100,100)],
     nil]];
     */
    //    [self addChildToSheet:player];
    
}

-(bool)inObject:(CGPoint) p {
    for (BridgeNode *n in self.currentLevel.bridges) {
        if (CGRectContainsPoint([n.bridge boundingBox], p)) {
            return true;
        }
    }
    
    for (Bridge4Node *n in self.currentLevel.bridge4s) {
        if (CGRectContainsPoint([n.bridge boundingBox], p)) {
            return true;
        }
    }
    
    for (RiverNode *n in self.currentLevel.rivers) {
        if (CGRectContainsPoint(n.frame, p)) {
            return true;
        }
    }
    
    for (HouseNode *h in self.currentLevel.houses) {
        if (CGRectContainsPoint([h.house boundingBox], p)) {
            return true;
        }
    }
    
    return false;
    
}

-(void)ccTouchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    
    // Choose one of the touches to work with
    UITouch *touch = [touches anyObject];
    CGPoint location = [touch locationInView:[touch view]];
    location = [[CCDirector sharedDirector] convertToGL:location];
    
    _inMove = false;
    
    if (_inBridge) {
        [self finishCross4:location];
        return;
    }
    
    if (_player == nil) {
        if (![self inObject:location]) {
            [self spawnPlayer:location.x: location.y];
        }
    } else {
        _inCross = false;
        _prevPlayerPos = _player.player.position;
        
        _playerStart = _player.player.position;
        [_player moveTo:location];
//        [_player.player runAction:
//         [CCMoveTo actionWithDuration:distance/velocity position:ccp(location.x,location.y)]];
    }
    
}

-(void)dealloc {
    
    delete _world;
    delete _debugDraw;
    
    delete _contactListener;
    [_spriteSheet release];
    [_player dealloc];
    
    [_undoStack release];
    _undoStack = nil;
    
    [self.currentLevel release];
    [self.undoBtn release];
    [self.coinLbl release];
    [self.coinImage release];
    [self.view release];
    [self.controller release];
    
//    [self.currentLevel dealloc];
    
    [super dealloc];
}

@end